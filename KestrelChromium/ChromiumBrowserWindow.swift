#if canImport(SwiftUI) && canImport(CefSwiftUI)

import CefSwiftUI
import Observation
import SwiftUI

struct ChromiumBrowserWindow: View {
    @Bindable var browser: ChromiumBrowserShell
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            toolbar
            progressStrip
            browserContents
        }
        .background(.background)
        .onChange(of: browser.selectedTabID) { _, _ in syncAddress() }
        .onChange(of: browser.selectedTab?.engine.url) { _, _ in
            if !addressFocused { syncAddress() }
        }
        .onChange(of: browser.addressFocusToken) { _, _ in addressFocused = true }
        .onAppear(perform: syncAddress)
    }

    private var tabStrip: some View {
        HStack(spacing: 5) {
            ForEach(browser.tabs) { tab in
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(tab.title)
                        .lineLimit(1)
                        .frame(maxWidth: 170, alignment: .leading)
                    Button { browser.close(tab) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    tab.id == browser.selectedTabID ? AnyShapeStyle(.background.opacity(0.95))
                        : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 7)
                )
                .contentShape(.rect(cornerRadius: 7))
                .onTapGesture { browser.select(tab) }
            }
            Button { _ = browser.newTab() } label: {
                Image(systemName: "plus")
                    .frame(width: 25, height: 25)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("New Tab")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 40)
        .background(.regularMaterial)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .help("Go Back")

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .help("Go Forward")

            Button {
                browser.isLoading ? browser.stopLoading() : browser.reload()
            } label: {
                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(browser.isLoading ? "Stop Loading" : "Reload")

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search or enter address", text: $addressText)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit {
                        browser.submitAddress(addressText)
                        addressFocused = false
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))

            Button { browser.toggleDevTools() } label: {
                Image(systemName: "hammer")
            }
            .help("Developer Tools")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var progressStrip: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.tint)
                .frame(width: geometry.size.width * browser.progress)
                .opacity(browser.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: browser.progress)
                .animation(.easeOut(duration: 0.25), value: browser.isLoading)
        }
        .frame(height: 2)
    }

    private var browserContents: some View {
        ZStack {
            ForEach(browser.tabs) { tab in
                CefMetalWebView(model: tab.engine)
                    .opacity(tab.id == browser.selectedTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == browser.selectedTabID)
                    .accessibilityHidden(tab.id != browser.selectedTabID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func syncAddress() {
        addressText = browser.selectedTab?.engine.url?.absoluteString ?? ""
    }
}

#endif
