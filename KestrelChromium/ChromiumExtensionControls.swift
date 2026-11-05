#if canImport(SwiftUI) && canImport(CefSwiftUI)
import AppKit
import SwiftUI

struct ExtensionActionIcon: View {
    let item: ChromiumExtensionDescriptor
    var body: some View {
        Group {
            if let url = item.iconURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else { Image(systemName: "puzzlepiece.extension") }
        }.frame(width: 16, height: 16).accessibilityHidden(true)
    }
}

struct ExtensionToolbarButton: View {
    @ObservedObject var tabs: TabStore
    let tabID: UUID
    var body: some View {
        Button { tabs.showExtensionMenu(for: tabID) } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tabs.canShowExtensionActions(for: tabID))
        .help("Open installed extensions and their site access controls")
        .accessibilityLabel("Show extensions")
        .background(ExtensionControlAnchor(name: "Show extensions").allowsHitTesting(false))
    }
}

struct PinnedToolbarExtensionActions: View {
    @ObservedObject var tabs: TabStore
    @ObservedObject private var catalogue = ChromiumInstalledExtensions.shared
    let tabID: UUID
    let limit: Int
    private var pinned: [ChromiumExtensionDescriptor] {
        catalogue.actions.filter { catalogue.pinnedActionIDs.contains($0.id) }
    }
    var body: some View {
        ForEach(Array(pinned.prefix(limit))) { item in
            Button { tabs.showExtensionAction(item.id, for: tabID) } label: {
                ExtensionActionIcon(item: item).frame(width: 26, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(item.name)")
            .accessibilityLabel("Open \(item.name) toolbar extension")
            .background(ExtensionControlAnchor(name: "Open \(item.name) toolbar extension").allowsHitTesting(false))
            .disabled(!tabs.canShowExtensionActions(for: tabID))
        }
    }
}

struct SidebarExtensionActions: View {
    @ObservedObject var tabs: TabStore
    @ObservedObject var settings: AppSettings
    @ObservedObject private var catalogue = ChromiumInstalledExtensions.shared
    let isCompact: Bool
    private var chosen: [ChromiumExtensionDescriptor] {
        catalogue.actions.filter { settings.extensions.showsSidebarAction($0.id) }
    }
    private var visible: [ChromiumExtensionDescriptor] {
        // Keep Chats reachable even in the narrow rail, including overflow.
        isCompact && chosen.count > 1 ? [] : Array(chosen.prefix(1))
    }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(visible) { item in
                Button { tabs.showExtensionAction(item.id, anchorLabel: "Open \(item.name) extension") } label: {
                    ExtensionActionIcon(item: item).frame(width: 26, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(item.name)")
                .accessibilityLabel("Open \(item.name) extension")
                .background(ExtensionControlAnchor(name: "Open \(item.name) extension").allowsHitTesting(false))
                .disabled(!tabs.canShowExtensionActions(for: tabs.selectedID))
            }
            if chosen.count > visible.count || chosen.isEmpty {
                Menu {
                    ForEach(chosen.dropFirst(visible.count)) { item in
                        Button(item.name) { tabs.showExtensionAction(item.id, anchorLabel: "More extensions") }
                            .disabled(!tabs.canShowExtensionActions(for: tabs.selectedID))
                    }
                    if !chosen.isEmpty { Divider() }
                    Button("All Extensions") { tabs.showExtensionMenu(for: tabs.selectedID, anchorLabel: "More extensions") }
                        .disabled(!tabs.canShowExtensionActions(for: tabs.selectedID))
                    Button("Manage Extensions…") { tabs.openChromiumExtensions() }
                } label: {
                    Image(systemName: visible.isEmpty ? "puzzlepiece.extension" : "ellipsis")
                        .frame(width: 24, height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Show more extensions").accessibilityLabel("More extensions")
                .background(ExtensionControlAnchor(name: "More extensions").allowsHitTesting(false))
            }
        }
    }
}

struct ExtensionPlacementSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var catalogue = ChromiumInstalledExtensions.shared
    var body: some View {
        SettingsToggle("Show extensions in the toolbar", isOn: $settings.extensions.toolbarActionsVisible)
        SettingsToggle("Show extensions beside Chats", isOn: $settings.extensions.sidebarActionsVisible)
            .help("Keep extension shortcuts beside the AI chat control in the sidebar")
        if settings.extensions.sidebarActionsVisible {
            if catalogue.actions.isEmpty {
                Text(catalogue.readFailed ? "The installed extension list is temporarily unavailable." : "Installed extension actions will appear here.")
                    .font(KestrelTypography.chromeDetail).foregroundStyle(.secondary)
            } else {
                ForEach(catalogue.actions) { item in
                    Toggle(isOn: Binding(
                        get: { settings.extensions.showsSidebarAction(item.id) },
                        set: { settings.extensions.setSidebarAction(item.id, visible: $0, availableIDs: catalogue.actions.map(\.id)) }
                    )) {
                        HStack(spacing: 8) { ExtensionActionIcon(item: item); Text(item.name) }
                    }.toggleStyle(.checkbox).font(KestrelTypography.chromeDetail)
                }
            }
        }
    }
}
#endif
