#if canImport(AppKit)
import AppKit

@MainActor
enum ChromiumNativeActionProbe {
    static func inspect(_ root: NSView) {
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
                    if role == "AXWebArea" { continue }
                    let label = element.accessibilityLabel() ?? ""
                    if role.contains("Button") || !label.isEmpty {
                        rows.append(["type":String(describing:type(of:next)),"role":role,"label":label])
                    }
                    queue += element.accessibilityChildren() ?? []
                }
                if let data = try? JSONSerialization.data(withJSONObject: ["count":seen.count,"nodes":rows]), let string=String(data:data,encoding:.utf8) {
                    try? FileHandle.standardError.write(contentsOf:Data(("KESTREL_IN_PROCESS_ACTION_AX "+string+"\n").utf8))
                    NSLog("KESTREL_IN_PROCESS_ACTION_AX %@", string)
                    let path = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("com.shayprasad.Kestrel/CefSwift/native-action-access-probe.jsonl")
                    if !FileManager.default.fileExists(atPath:path.path) { FileManager.default.createFile(atPath:path.path,contents:nil) }
                    if let file=try? FileHandle(forWritingTo:path) { try? file.seekToEnd(); try? file.write(contentsOf:Data((string+"\n").utf8));try? file.close() }
                }
            }
        }
    }
}
#endif
