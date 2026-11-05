#if canImport(AppKit)
import AppKit

@MainActor
enum ChromiumNativeActionProbe {
    static func inspect(_ root: NSView) {
        guard ProcessInfo.processInfo.arguments.contains("--kestrel-extension-toolbar-probe") else { return }
        Task { @MainActor [weak root] in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let root else { return }
                var queue: [Any] = [root]
                var seen = Set<ObjectIdentifier>()
                var rows: [[String:String]] = []
                while !queue.isEmpty && seen.count < 2048 {
                    let next = queue.removeFirst() as AnyObject
                    guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
                    guard let element = next as? NSAccessibilityProtocol else {
                        rows.append(["unavailable": String(describing: type(of: next))]); continue
                    }
                    let role = element.accessibilityRole()?.rawValue ?? ""
                    let label = element.accessibilityLabel() ?? ""
                    if role.contains("Button") || !label.isEmpty {
                        rows.append(["type":String(describing:type(of:next)),"role":role,"label":label])
                    }
                    queue += element.accessibilityChildren() ?? []
                }
                if let data = try? JSONSerialization.data(withJSONObject: ["count":seen.count,"nodes":rows]), let string=String(data:data,encoding:.utf8) {
                    try? FileHandle.standardError.write(contentsOf:Data(("KESTREL_IN_PROCESS_ACTION_AX "+string+"\n").utf8))
                }
            }
        }
    }
}
#endif
