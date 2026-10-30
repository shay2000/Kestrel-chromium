// A native companion owns the login-agent registration. macOS does not permit
// a sandboxed browser to register an unsandboxed agent directly.
import AppKit
import ServiceManagement

@MainActor final class CodexHostDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let service = SMAppService.agent(plistName: "com.shayprasad.Kestrel.CodexAgent.plist")
            do {
                // Refresh launchd's signing requirement after a rebuilt app.
                if service.status == .enabled || service.status == .requiresApproval {
                    try await service.unregister()
                }
                if !CommandLine.arguments.contains("--disable") { try service.register() }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not enable Kestrel’s Codex helper"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
@main struct CodexHostApp {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--agent") {
            try CodexAgentMain.main()
            return
        }
        let application = NSApplication.shared
        let delegate = CodexHostDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
