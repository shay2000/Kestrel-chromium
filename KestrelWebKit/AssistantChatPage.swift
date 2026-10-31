#if canImport(SwiftUI) && canImport(CefSwiftUI)

import SwiftUI
import AppKit

/// The assistant conversation as a column of rows.
///
/// Shared by the sidecar and the assistant page. These used to be two separate
/// renderings of the same `ChatItem` list, which is exactly the kind of pair
/// that drifts: a new row type would be added to one and forgotten in the
/// other, and an approval prompt that only appeared in the sidecar would be an
/// action the user could not approve from the page. Only the measurements
/// differ — the page gets a measured column in the middle of a wide pane, the
/// sidecar fills its own narrow one.
struct AssistantTranscript: View {
    @ObservedObject var chat: AIChatStore
    @ObservedObject var settings: AppSettings
    let style: Style
    var pageContext: PageContext? = nil

    /// The one source list that is open. New answers stay collapsed until the
    /// user chooses to inspect their sources, keeping long research chats
    /// readable without hiding citations.
    @State private var expandedSourceRowID: UUID?
    @State private var activityExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var transcriptAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.20)
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: 0, y: 6))
    }

    enum Style: Equatable {
        /// The sidecar: fills the narrow pane it lives in.
        case sidebar
        /// The assistant page: a measured column centred in a wide pane.
        case page

        var horizontalPadding: CGFloat { self == .sidebar ? 14 : 30 }
        var verticalPadding: CGFloat { self == .sidebar ? 16 : 28 }
        var rowSpacing: CGFloat { self == .sidebar ? 15 : 20 }

        /// nil means "as wide as the pane it is in".
        ///
        /// A wide window is a bad place for a line of prose: at 1,200 points a
        /// paragraph runs to roughly 150 characters and the eye loses its place
        /// on the way back. The page therefore caps the column and centres it,
        /// while the sidecar simply uses what it has.
        var columnWidth: CGFloat? { self == .sidebar ? nil : 680 }
        var bodyFont: Font { self == .page ? KestrelTypography.assistantPageBody : KestrelTypography.body }
        var calloutFont: Font { self == .page ? KestrelTypography.assistantPageSupporting : KestrelTypography.callout }
        var footnoteFont: Font { self == .page ? KestrelTypography.assistantPageSupporting : KestrelTypography.footnote }
        var captionFont: Font { self == .page ? KestrelTypography.assistantPageProgress : KestrelTypography.caption }
        var codeFont: Font { self == .page ? KestrelTypography.assistantPageCode : KestrelTypography.code }
        var tableFont: Font { self == .page ? KestrelTypography.assistantPageTable : KestrelTypography.caption }

        func headingFont(level: Int) -> Font {
            if self == .page {
                return level <= 2 ? KestrelTypography.assistantPageHeading : KestrelTypography.assistantPageSubheading
            }
            return level <= 2
                ? KestrelTypography.sectionTitle
                : KestrelTypography.callout.weight(.semibold)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: style.rowSpacing) {
                    if let context = pageContext {
                        HStack {
                            Spacer(minLength: 36)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text("Last page read")
                                    .font(style.captionFont)
                                    .foregroundStyle(.secondary)
                                PageContextCard(context: context,
                                    faviconURL: BrowserBookmark(title: context.title, urlString: context.url).faviconSourceURL)
                            }
                            .frame(maxWidth: 340, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    ForEach(chat.items) { item in
                        row(for: item)
                            .id(item.id)
                            .transition(rowTransition)
                    }
                    if chat.isBusy || !chat.activityEntries.isEmpty {
                        DisclosureGroup(isExpanded: $activityExpanded) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Live activity and action summaries")
                                        .font(style.captionFont.weight(.semibold))
                                    Text("Shows progress and browser decisions, rather than private internal reasoning.")
                                        .font(style.captionFont)
                                        .foregroundStyle(.secondary)
                                    ForEach(Array(chat.activityEntries.enumerated()), id: \.offset) { _, entry in
                                        Text(entry)
                                            .font(style.captionFont)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .frame(maxHeight: 140)
                            .padding(.top, 8)
                        } label: {
                            HStack(spacing: 8) {
                                if chat.isBusy {
                                    ThinkingDots(dotSize: 5, tint: .secondary)
                                } else {
                                    Image(systemName: "list.bullet")
                                        .foregroundStyle(.secondary)
                                }
                                Text(chat.activityMessage ?? chat.activityEntries.last ?? "Working…")
                                    .font(style.captionFont)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .contentTransition(.opacity)
                            }
                            .accessibilityLabel("Agent activity")
                        }
                        .padding(11)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                        .id("assistant-thinking")
                        .transition(rowTransition)
                    }
                }
                .animation(transcriptAnimation, value: chat.items.map(\.id))
                .animation(transcriptAnimation, value: chat.isBusy)
                .animation(transcriptAnimation, value: chat.activityMessage)
                .animation(transcriptAnimation, value: chat.isSearchingWeb)
                .padding(.horizontal, style.horizontalPadding)
                .padding(.vertical, style.verticalPadding)
                .frame(maxWidth: style.columnWidth ?? .infinity, alignment: .leading)
                // The outer frame is what centres a capped column: the inner one
                // sizes it, this one places it.
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .onChange(of: chat.items.map(\.id)) { _, _ in
                guard let last = chat.items.last else { return }
                // Keep each new source list minimised. The user opens only the
                // citations they want to inspect.
                if case .message(let message) = last, message.role == .user {
                    expandedSourceRowID = nil
                    activityExpanded = false
                } else if case .sources = last {
                    expandedSourceRowID = nil
                }
                withAnimation(transcriptAnimation) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: chat.isBusy) { _, isBusy in
                if isBusy {
                    withAnimation(transcriptAnimation) { proxy.scrollTo("assistant-thinking", anchor: .bottom) }
                }
            }
            .onChange(of: chat.activityMessage) { _, message in
                guard chat.isBusy, message != nil else { return }
                withAnimation(transcriptAnimation) { proxy.scrollTo("assistant-thinking", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(for item: ChatItem) -> some View {
        switch item {
        case .message(let message):
            messageRow(message)
        case .notice(_, let text):
            if !text.hasPrefix("Read current-page context:") && !text.hasPrefix("Read visible search results:") {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(text)
                        .font(style.footnoteFont)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        case .cursorChoice(let prompt):
            cursorChoiceRow(prompt)
        case .proposal(let proposal):
            proposalRow(proposal)
        case .result(_, let result):
            resultRow(result)
        case .sources(let id, let sources):
            sourceRow(id: id, sources: sources)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: AIMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 30)
                VStack(alignment: .leading, spacing: message.attachments.isEmpty ? 0 : 8) {
                    Text(message.text)
                        .font(style.bodyFont)
                        .textSelection(.enabled)
                    if !message.attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(message.attachments) { source in
                                    let thumbnail = NewTabAttachment(
                                        id: source.id,
                                        kind: source.kind,
                                        label: source.label,
                                        origin: source.origin,
                                        text: ""
                                    )
                                    HStack(spacing: 5) {
                                        NewTabAttachmentThumbnail(attachment: thumbnail)
                                        Text(source.label)
                                            .font(style.captionFont)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        ComposerAccessoryPalette.composerSurface(isDark: colorScheme == .dark),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(ComposerAccessoryPalette.composerSurfaceEdge(isDark: colorScheme == .dark), lineWidth: 0.7)
                                    }
                                    .help(source.origin)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "You: \(message.text)"
                    + (message.attachments.isEmpty ? "" : ", sources: " + message.attachments.map(\.label).joined(separator: ", "))
            )
        } else {
            AssistantMarkdownView(markdown: message.text, style: style)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Markdown is a compound, selectable view. Expose one stable
                // transcript label instead of resolving a parent's label
                // through every nested Markdown selection element. Describe
                // the rendered structure without speaking Markdown markers.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Assistant: \(AssistantMarkdownParser.accessibilityText(message.text))")
        }
    }

    private func proposalRow(_ proposal: ProposedAction) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Review before running", systemImage: "hand.tap")
                .font(style.calloutFont)
            Text(proposal.action.summary)
                .font(style.calloutFont)
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale)
                    .font(style.footnoteFont)
                    .foregroundStyle(.secondary)
            }
            Text("Nothing happens until you approve it.")
                .font(style.captionFont)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private func resultRow(_ result: ActionResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(result.summary)
            } icon: {
                Image(systemName: result.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
            }
            .font(style.calloutFont)
            if let detail = result.detail, !detail.isEmpty {
                Text(detail)
                    .font(style.footnoteFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The sources behind a search-grounded answer.
    ///
    /// The list is a collapsed "Sources" button by default, showing the first
    /// few favicons, and opens into a grid of equal cards. A new question folds
    /// the previous lists back to their buttons, so a long research chat stays
    /// readable while every citation is still one click away.
    @ViewBuilder
    private func sourceRow(id: UUID, sources: [AssistantSource]) -> some View {
        let isExpanded = expandedSourceRowID == id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(transcriptAnimation) {
                    expandedSourceRowID = isExpanded ? nil : id
                }
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: -5) {
                        ForEach(Array(sources.prefix(3).enumerated()), id: \.element.id) { _, source in
                            SourceFaviconView(url: source.faviconURL, size: 12)
                                .padding(3)
                                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                                }
                        }
                    }
                    Text("Sources")
                        .font(style.footnoteFont)
                    Text("\(sources.count)")
                        .font(style.captionFont)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(ComposerAccessoryPalette.composerSurface(isDark: colorScheme == .dark))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(ComposerAccessoryPalette.composerSurfaceEdge(isDark: colorScheme == .dark), lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.035 : 0.84), lineWidth: 0.8)
                        .padding(1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.17 : 0.085), radius: 7, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the sources" : "Show the sources")
            .accessibilityLabel("Sources, \(sources.count)")
            .accessibilityHint(isExpanded ? "Collapses the source list" : "Expands the source list")

            if isExpanded {
                LazyVGrid(
                    columns: style == .sidebar
                        ? [GridItem(.flexible())]
                        : [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(sources) { source in
                        sourceCard(source)
                    }
                }
            }
        }
    }

    /// One source. Every card is the same height and the grid uses a fixed
    /// column count, so the row reads as a set of tiles rather than a ragged
    /// line of differently sized boxes.
    private func sourceCard(_ source: AssistantSource) -> some View {
        Button {
            guard let url = URL(string: source.url) else { return }
            chat.openExternalURL(url)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                SourceFaviconView(url: source.faviconURL)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(style.footnoteFont)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text(Self.hostLabel(for: source.url))
                        .font(style.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(
                maxWidth: .infinity,
                minHeight: style == .page ? 76 : 58,
                maxHeight: style == .page ? 76 : 58,
                alignment: .topLeading
            )
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ComposerAccessoryPalette.composerSurface(isDark: colorScheme == .dark))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ComposerAccessoryPalette.composerSurfaceEdge(isDark: colorScheme == .dark), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.035 : 0.78), lineWidth: 0.8)
                    .padding(1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.13 : 0.065), radius: 6, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open source in a background tab")
        .accessibilityLabel("Source: \(source.title), \(Self.hostLabel(for: source.url))")
        .accessibilityHint("Opens in a background tab")
    }

    static func hostLabel(for urlString: String) -> String {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func cursorChoiceRow(_ prompt: CursorChoicePrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How should Kestrel continue?", systemImage: "safari")
                .font(style.calloutFont)
            Text(settings.autoApproveSafeBrowsing
                ? "Search the web for an answer, or let Kestrel use this page. Routine navigation follows your safe-browsing setting; page changes still need approval."
                : "Search the web for an answer, or let Kestrel use this page. With safe browsing off, navigation and page changes need approval.")
                .font(style.footnoteFont)
                .foregroundStyle(.secondary)

            if let choice = prompt.choice {
                Label(
                    choice == .operate ? "Page controls selected" : "Searching the web",
                    systemImage: choice == .operate ? "safari" : "magnifyingglass"
                )
                .font(style.footnoteFont)
                .foregroundStyle(.secondary)
            } else {
                Text("Web search reads visible results and sends them to your selected assistant provider.")
                    .font(style.captionFont)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Search the web") { chat.chooseCursorAssistance(false) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Use page controls") { chat.chooseCursorAssistance(true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.11), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Composes the two stores that opening a chat needs, so the rail, the Chats
/// menu and the Assistant menu cannot disagree about what "open this chat"
/// means.
enum AssistantChatLauncher {
    /// Opens or reselects the Assistant page without changing the active
    /// conversation, provider or unsent draft. This is the New Tab route when
    /// Settings chooses the full Assistant page for answers.
    @MainActor
    static func showCurrent(tabs: TabStore, chat: AIChatStore) {
        tabs.dismissNewTabSearch()
        chat.isSidebarVisible = false
        tabs.openAssistantTab()
    }

    /// The primary Assistant control preserves the current conversation. An
    /// empty tab gives it a page; a website keeps its place beside the chat.
    @MainActor
    static func toggle(tabs: TabStore, chat: AIChatStore) {
        if tabs.selectedTabHasNoPage || tabs.isAssistantTab(tabs.selectedID) {
            showCurrent(tabs: tabs, chat: chat)
        } else {
            tabs.dismissNewTabSearch()
            chat.toggleSidebar()
        }
    }

    /// Shows the assistant page, loaded with `conversationID` — or with a fresh
    /// conversation when that is nil.
    @MainActor
    static func open(_ conversationID: UUID?, tabs: TabStore, chat: AIChatStore) {
        if let conversationID {
            chat.openConversation(conversationID)
        } else {
            chat.clearConversation()
        }
        showCurrent(tabs: tabs, chat: chat)
    }
}

/// The list of chats, shared by the rail's Chats control and the Chats menu in
/// the menu bar.
///
/// Both surfaces take plain view content, so one list serves them both: a chat
/// that appears in the menu bar is the same chat, in the same order, as the one
/// in the rail.
struct AssistantChatMenuItems: View {
    @ObservedObject var chat: AIChatStore
    let open: (UUID?) -> Void

    var body: some View {
        Button("New Chat") { open(nil) }
            .help("Start a fresh assistant conversation")

        if chat.savedConversations.isEmpty {
            Text("No saved chats")
        } else if chat.savedConversations.count <= AssistantChatMenuLayout.conversationsPerGroup {
            Divider()
            ForEach(chat.savedConversations) { conversation in
                conversationButton(conversation)
            }
        } else {
            Divider()
            ForEach(Array(AssistantChatMenuLayout.groups(for: chat.savedConversations.count).enumerated()), id: \.offset) { group in
                Menu(AssistantChatMenuLayout.title(forGroup: group.offset, range: group.element)) {
                    ForEach(Array(chat.savedConversations[group.element])) { conversation in
                        conversationButton(conversation)
                    }
                }
            }
        }
    }

    private func conversationButton(_ conversation: AssistantConversation) -> some View {
        Button(AssistantConversation.menuTitle(for: conversation.title)) {
            open(conversation.id)
        }
        .help("Reopen chat: \(conversation.title)")
        // Switching conversations mid-answer would leave the reply arriving
        // into a transcript it no longer belongs to.
        .disabled(!chat.canSwitchConversation)
    }
}

struct AssistantComposerHandoffEffect: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "assistant-composer-surface", in: namespace)
        } else {
            content
        }
    }
}

/// The assistant as a page rather than a sidecar.
///
/// The New Tab AI route uses this when Settings sends answers to the full
/// Assistant page. The conversation gets the whole pane, so answers are read at a
/// comfortable measure instead of in a 370-point column, and the composer
/// floats under the transcript the way it does in the reference.
struct AssistantChatPage: View {
    @ObservedObject var chat: AIChatStore
    @ObservedObject var settings: AppSettings
    let composerNamespace: Namespace.ID?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool

    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.20)
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: 0, y: 5))
    }

    var body: some View {
        VStack(spacing: 0) {
            if chat.items.isEmpty {
                emptyState
                    .transition(pageTransition)
            } else {
                AssistantTranscript(chat: chat, settings: settings, style: .page)
                    .id(chat.currentConversationID)
                    .transition(pageTransition)
            }

            if let errorMessage = chat.errorMessage {
                errorBanner(errorMessage)
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 10)
            }

            if let proposal = chat.pendingProposal {
                proposalBar(proposal)
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 10)
            }

            AssistantComposer(
                chat: chat,
                settings: settings,
                inputFocused: $inputFocused,
                composerNamespace: composerNamespace
            )
                .id(chat.currentConversationID)
                .frame(maxWidth: 680)
                .padding(.horizontal, 30)
                .padding(.top, 12)
                .padding(.bottom, 22)
        }
        .fontDesign(.default)
        .animation(pageAnimation, value: chat.items.isEmpty)
        .task(id: chat.currentConversationID) {
            // A new conversation replaces the composer. Release the outgoing
            // field before focusing the newly mounted native editor.
            inputFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            inputFocused = true
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            ProviderMark(provider: settings.ai.selectedProvider, size: 34)

            Text("Ask anything")
                .font(KestrelTypography.assistantPageTitle)

            if let issue = chat.configurationIssue {
                VStack(spacing: 8) {
                    Text(issue)
                        .font(KestrelTypography.assistantPageSupporting)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Button("Open Settings") { openSettings() }
                        .controlSize(.small)
                        .help("Open Kestrel Settings to configure the selected assistant")
                }
            } else {
                Text("Kestrel answers directly or searches the web when current information would help.")
                    .font(KestrelTypography.assistantPageSupporting)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(KestrelTypography.assistantPageSupporting)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                chat.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss this assistant error")
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
                    .font(KestrelTypography.assistantPageSupporting)
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
        .font(KestrelTypography.assistantPageSupporting)
        .padding(9)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval required for \(proposal.action.summary)")
    }
}

/// Local, ephemeral details: never part of the saved conversation or provider request.
struct ProfileFillApprovalPreview: View {
    let preview: ProfileFillPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Share these details with " + (URL(string: preview.destination)?.host ?? preview.destination)).font(.headline)
            Text(preview.destination).font(.caption).textSelection(.enabled)
            if preview.fields.count <= 4 && preview.fields.reduce(0, { $0 + $1.value.count }) <= 240 {
                fieldList
            } else {
                ScrollView { fieldList }.frame(maxHeight: 190)
            }
            Text("The website can read these details as soon as they are filled. Kestrel will not submit the form. Decline to edit About me first.").font(.caption)
        }
    }
    private var fieldList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(preview.fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.fields[index].label).font(.caption).foregroundStyle(.secondary)
                    Text(preview.fields[index].value).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// The model picker sits above the message box, leaving its full width for
/// the draft and a single row of action controls, including in narrow panes.
struct AssistantComposer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var chat: AIChatStore
    @ObservedObject var settings: AppSettings
    @FocusState.Binding var inputFocused: Bool
    let composerNamespace: Namespace.ID?
    @State private var modelPickerIsPresented = false
    private var attachments: [NewTabAttachment] {
        get { chat.draftAttachments }
        nonmutating set { chat.draftAttachments = newValue }
    }
    private var attachmentError: String? {
        get { chat.draftAttachmentError }
        nonmutating set { chat.draftAttachmentError = newValue }
    }
    @State private var pendingModelSelection: PendingAssistantModelSelection?
    @ObservedObject private var modelCache = ProviderModelCache.shared

    private struct PendingAssistantModelSelection: Identifiable {
        let provider: AIProviderKind
        let modelID: String
        let capacity: AttachmentCapacity
        var id: String { "\(provider.rawValue)|\(modelID)" }
    }

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
            : "\(attachmentCapacity.maximumFiles) files"
        let excess = overBy == 1 ? "1 file" : "\(overBy) files"
        return "This model supports up to \(maximum). Remove \(excess) before sending, or choose a model with a higher limit."
    }

    private var canSend: Bool {
        !chat.isBusy && chat.pendingProposal == nil && chat.pendingCursorPrompt == nil
            && attachments.count <= attachmentCapacity.maximumFiles
            && (!chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                modelControl
                Spacer(minLength: 0)
                configurationWarning
            }
            .padding(.horizontal, 14)
            messageBox
        }
    }

    private var messageBox: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                .frame(height: 40)
                .accessibilityLabel("Attached files")
                .transition(attachmentTransition)
            }

            if let attachmentError = attachmentError ?? attachmentLimitWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(attachmentError)
                        .font(KestrelTypography.assistantPageSupporting)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.orange)
                .transition(attachmentTransition)
            }

            TextField("Ask a question…", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(KestrelTypography.assistantPageBody)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit(sendMessage)
                .disabled(chat.isBusy || chat.pendingProposal != nil || chat.pendingCursorPrompt != nil)
                .help("Write a question for the selected assistant. You can attach files below. Web search is controlled in Settings.")
                .accessibilityLabel("Assistant message")
                .frame(minHeight: 32, alignment: .leading)

            HStack(spacing: 8) {
                attachmentControl
                browseControl
                Spacer(minLength: 0)
                sendControl
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ComposerAccessoryPalette.composerSurface(isDark: colorScheme == .dark))
                .modifier(AssistantComposerHandoffEffect(namespace: composerNamespace))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(ComposerAccessoryPalette.composerSurfaceEdge(isDark: colorScheme == .dark), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.035 : 0.82), lineWidth: 0.8)
                .padding(1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.07), radius: 9, x: 0, y: 4)
        .shadow(color: ComposerAccessoryPalette.lavender.opacity(colorScheme == .dark ? 0.025 : 0.09), radius: colorScheme == .dark ? 7 : 10, x: 0, y: 4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: attachments.count)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: attachmentError)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: attachmentLimitWarning)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: attachmentCapacity.maximumFiles)
        .confirmationDialog(
            "This model has a smaller file limit",
            isPresented: Binding(
                get: { pendingModelSelection != nil },
                set: { if !$0 { pendingModelSelection = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingModelSelection
        ) { pending in
            Button("Switch and keep files") { applyModelSelection(provider: pending.provider, modelID: pending.modelID) }
                .keyboardShortcut(.defaultAction)
            Button("Keep current model", role: .cancel) { pendingModelSelection = nil }
        } message: { pending in
            let attached = attachments.count == 1 ? "1 attached file" : "\(attachments.count) attached files"
            let maximum = pending.capacity.maximumFiles == 1
                ? "1 file"
                : "up to \(pending.capacity.maximumFiles) files"
            let excess = attachments.count - pending.capacity.maximumFiles
            let remove = excess == 1 ? "1 file" : "\(excess) files"
            Text("You have \(attached). \(pending.provider.displayName) supports \(maximum). Your attachments will stay here. Remove \(remove) before sending, or choose a model with a higher limit.")
        }
    }

    @ViewBuilder
    private var modelControl: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { modelPickerIsPresented.toggle() }
        } label: {
            HStack(spacing: 5) {
                ProviderMark(provider: settings.ai.selectedProvider, size: 16)
                AssistantModelSelectionLabel(settings: settings)
                Image(systemName: modelPickerIsPresented ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(ComposerAccessoryPalette.accessoryForeground(
                isActive: modelPickerIsPresented,
                isDark: colorScheme == .dark
            ))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ComposerAccessorySurface(isActive: modelPickerIsPresented))
        .background {
            AssistantModelPopover(isPresented: $modelPickerIsPresented, settings: settings,
                                  onModelSelectionRequested: requestModelSelection)
        }
        .help("Choose the assistant model or provider")
        .accessibilityLabel("Assistant model: \(settings.ai.selectedProvider.displayName)")
        .accessibilityValue(settings.ai.settings(for: settings.ai.selectedProvider).model)
    }

    @ViewBuilder
    private var configurationWarning: some View {
        if let issue = chat.configurationIssue {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help(issue)
                .accessibilityLabel("Assistant setup needs attention")
                .frame(width: 30, height: 32)
        }
    }

    @ViewBuilder
    private var attachmentControl: some View {
        Button(action: uploadFiles) {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ComposerAccessoryPalette.accessoryForeground(isActive: false, isDark: colorScheme == .dark))
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

    private var browseControl: some View {
        AgentModeControl(chat: chat)
    }

    @ViewBuilder
    private var sendControl: some View {
        if chat.isBusy {
            Button(action: chat.cancel) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.11), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop the current assistant or browser action")
            .accessibilityLabel("Stop assistant")
        } else {
            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send this question and any attached files to the selected assistant")
            .accessibilityLabel("Send message")
        }
    }

    private var attachmentTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4))
    }

    private func attachmentChip(_ attachment: NewTabAttachment) -> some View {
        HStack(spacing: 6) {
            NewTabAttachmentThumbnail(attachment: attachment)
            Text(attachment.label)
                .font(KestrelTypography.assistantPageSupporting.weight(.medium))
                .lineLimit(1)
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove \(attachment.label)")
            .accessibilityLabel("Remove \(attachment.label)")
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.leading, 10)
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

    /// Returns false when a lower file cap needs confirmation. Existing
    /// attachments are never removed as a side effect of changing providers.
    private func requestModelSelection(provider: AIProviderKind, modelID: String) -> Bool {
        let selected = settings.ai.settings(for: provider)
        let nextCapacity = AttachmentCapacity.forModel(
            provider: provider,
            contextWindow: modelCache.contextWindow(provider: provider, modelID: modelID, configuration: selected)
        )
        if attachments.count > nextCapacity.maximumFiles {
            pendingModelSelection = PendingAssistantModelSelection(
                provider: provider,
                modelID: modelID,
                capacity: nextCapacity
            )
            return false
        }
        applyModelSelection(provider: provider, modelID: modelID)
        return true
    }

    private func applyModelSelection(provider: AIProviderKind, modelID: String) {
        var ai = settings.ai
        ai.selectedProvider = provider
        var configuration = ai.settings(for: provider)
        configuration.model = modelID
        ai.update(configuration)
        settings.ai = ai
        pendingModelSelection = nil
        attachmentError = nil
    }

    private func sendMessage() {
        guard !chat.isBusy, chat.pendingProposal == nil, chat.pendingCursorPrompt == nil else { return }
        guard attachments.count <= attachmentCapacity.maximumFiles else { return }
        guard !attachments.isEmpty else {
            chat.send(allowsWebSearch: settings.assistantWebSearchEnabled)
            return
        }

        let pending = attachments
        let prompt = NewTabAttachmentBuilder.question(chat.input, attachments: pending)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
}

/// The assistant page's row in the title-bar strip.
///
/// The chat title and actions occupy the same solid header as a New Tab page.
/// The containing card owns the outer rounding and window inset.
struct AssistantPageHeader: View {
    @ObservedObject var chat: AIChatStore
    @Environment(\.colorScheme) private var colorScheme
    let leadingInset: CGFloat
    let onNewChat: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(chat.conversationTitle ?? "Assistant")
                .font(KestrelTypography.chromeLabel.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.78))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(chat.items.isEmpty && chat.input.isEmpty && chat.draftAttachments.isEmpty)
            .help("Start a new chat")
            .accessibilityLabel("Start a new chat")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.78))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close this chat")
            .accessibilityLabel("Close this chat")
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(height: BrowserChromeLayout.toolbarHeight)
        .background(colorScheme == .dark ? kestrelNewTabCanvas : Color(nsColor: .windowBackgroundColor))
    }
}

/// Show the model as well as its provider so the pill describes the actual
/// selection before the user opens it. Keep the full value available to AX.
struct AssistantModelSelectionLabel: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var cache = ProviderModelCache.shared

    private var modelName: String? {
        let provider = settings.ai.selectedProvider
        let configuration = settings.ai.settings(for: provider)
        guard provider != .appleLocalModel, !configuration.model.isEmpty else { return nil }
        for style in ["compact", "regular"] {
            let key = ProviderModelCache.catalogueKey(provider: provider, settings: configuration, style: style)
            if let model = cache.models(for: key)?.first(where: { $0.id == configuration.model }) {
                return model.name
            }
        }
        return ProviderModelCatalogue.recommendedModels(for: provider)
            .first(where: { $0.modelID == configuration.model })?.name ?? configuration.model
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(settings.ai.selectedProvider.displayName)
                .font(KestrelTypography.callout)
            if let modelName {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(modelName)
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// Keep the native popover attached to the actual pill rather than a SwiftUI
/// presentation snapshot. AppKit animates from that source rect and keeps it
/// attached when the window moves; transient dismissal also handles Escape.
struct AssistantModelPopover: NSViewRepresentable {
    @Binding var isPresented: Bool
    let settings: AppSettings
    var onModelSelectionRequested: ((AIProviderKind, String) -> Bool)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    final class AnchorView: NSView {
        var didAttach: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); didAttach?() }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        let popover = NSPopover()
        var wantsPresentation = false
        var setPresented: ((Bool) -> Void)?
        override init() {
            super.init()
            popover.behavior = .transient
            popover.delegate = self
        }
        func show(from view: NSView) {
            guard wantsPresentation, !popover.isShown, view.window != nil,
                  !view.bounds.isEmpty else { return }
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        }
        func popoverDidClose(_ notification: Notification) {
            wantsPresentation = false
            // Release view tasks and search drafts on dismissal. Reopening
            // gets fresh callbacks and retries failed catalogues; successful
            // lists still come from the shared bounded cache.
            popover.contentViewController = nil
            setPresented?(false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.didAttach = { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.show(from: view) }
        }
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.setPresented = { value in
            // Delegate callbacks can arrive while SwiftUI is updating a view.
            DispatchQueue.main.async { isPresented = value }
        }
        coordinator.wantsPresentation = isPresented
        coordinator.popover.animates = !reduceMotion
        coordinator.popover.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if isPresented {
            if coordinator.popover.contentViewController == nil {
                let controller = NSHostingController(rootView: AssistantModelMenu(
                    settings: settings, onModelSelectionRequested: onModelSelectionRequested,
                    onClose: { [weak coordinator] in coordinator?.popover.performClose(nil) }
                ))
                controller.sizingOptions = [.preferredContentSize]
                coordinator.popover.contentViewController = controller
            }
            DispatchQueue.main.async { [weak view, weak coordinator] in
                if let view { coordinator?.show(from: view) }
            }
        } else if coordinator.popover.isShown {
            coordinator.popover.performClose(nil)
        }
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.didAttach = nil
        coordinator.wantsPresentation = false
        coordinator.setPresented = nil
        coordinator.popover.close()
    }
}

/// One mode control shared by both composers, always explicit and session-only.
struct AgentModeControl: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var chat: AIChatStore
    var body: some View {
        HStack(spacing: 0) {
            Button { chat.togglePageControl() } label: {
                HStack(spacing: 5) {
                    AgentModePointer()
                    Text("Agent mode")
                }
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .frame(height: 32)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent mode")
            .accessibilityValue(chat.isPageControlArmed ? "On" : "Off")
            Menu {
                Text("Works automatically until checkout or an action needs your attention.")
                if chat.isBusy { Button("Stop task") { chat.cancel() } }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.leading, 3)
                    .padding(.trailing, 9)
                    .frame(height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Agent mode options")
        }
        .fixedSize()
        .font(.system(.footnote, weight: .medium))
        .foregroundStyle(ComposerAccessoryPalette.accessoryForeground(isActive: chat.isPageControlArmed, isDark: colorScheme == .dark))
        .modifier(ComposerAccessorySurface(isActive: chat.isPageControlArmed))
        .disabled(!chat.canArmPageControl)
        .help(chat.pageControlHelp)
    }
}

/// The provider list and model picker, shared by both composers.
///
/// Extracted so the sidecar and the page cannot end up offering different
/// models: whichever surface the user opens, the same providers are listed in
/// the same order with the same selection marked.
struct AssistantModelMenu: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    var onModelSelectionRequested: ((AIProviderKind, String) -> Bool)?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose a model")
                    .font(KestrelTypography.chromeLabel.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close model picker")
                .accessibilityLabel("Close model picker")
            }
            if [.codexCLI, .workBuddyCLI].contains(settings.ai.selectedProvider) {
                Picker("Thinking", selection: $settings.ai.reasoning) {
                    ForEach(AssistantReasoning.allCases) { level in Text(level.title).tag(level) }
                }
                .pickerStyle(.segmented)
                .help("Fast uses less reasoning; Thorough takes more time. Balanced is the default. Applies to the next request.")
            }
            Text("Provider")
                .font(KestrelTypography.chromeDetail.weight(.semibold))
                .foregroundStyle(.secondary)
            // Two columns keep ten providers compact enough that the popover
            // stays on screen instead of growing a long list of rows.
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 5),
                    GridItem(.flexible(), spacing: 5)
                ],
                spacing: 5
            ) {
                ForEach(AIProviderKind.allCases) { provider in
                    providerButton(provider)
                }
            }

            Divider()

            ProviderModelPicker(
                settings: settings,
                provider: settings.ai.selectedProvider,
                style: .compact,
                onModelSelectionRequested: onModelSelectionRequested,
                onModelChosen: onClose
            )
        }
        // The native popover already draws the material, arrow and shadow. A
        // second glass/material fill inside it stacked two translucent layers
        // and showed as a seam along the bottom edge, so the content is laid
        // out plainly and the popover provides the chrome.
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 360)
    }

    private func providerButton(_ provider: AIProviderKind) -> some View {
        let isSelected = provider == settings.ai.selectedProvider
        let selectedColour = ComposerAccessoryPalette.accessoryForeground(
            isActive: true,
            isDark: colorScheme == .dark
        )
        return Button {
            if let onModelSelectionRequested {
                let model = settings.ai.settings(for: provider).model
                _ = onModelSelectionRequested(provider, model)
            } else {
                settings.ai.selectedProvider = provider
            }
        } label: {
            HStack(spacing: 6) {
                ProviderMark(provider: provider, size: 15)
                    .frame(width: 18, height: 18)
                Text(provider.displayName)
                    .font(.system(.footnote, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selectedColour)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                isSelected ? selectedColour.opacity(colorScheme == .dark ? 0.22 : 0.14) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? selectedColour.opacity(colorScheme == .dark ? 0.35 : 0.28) : Color.clear,
                        lineWidth: 0.8
                    )
            }
        }
        .buttonStyle(.plain)
        .help(provider.displayName)
        .accessibilityLabel(provider.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The favicon for a source card.
///
/// The icon is fetched from the result's own origin (`/favicon.ico`), never a
/// third-party favicon service, so opening the transcript does not tell anyone
/// else which sites were cited. A site with no readable icon falls back to a
/// globe rather than a broken image.
private struct SourceFaviconView: View {
    let url: URL?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .empty:
                        ProgressView().controlSize(.mini)
                    default:
                        globe
                    }
                }
            } else {
                globe
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var globe: some View {
        Image(systemName: "globe")
            .font(.system(size: max(9, size * 0.8)))
            .foregroundStyle(.secondary)
    }
}

#endif
