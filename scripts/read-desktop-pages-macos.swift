// Read-only renderer evidence for the disposable local desktop fixture.
import Foundation

@main
struct DesktopPages {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let port = UInt16(arguments[1]), port > 0,
              let fixture = URL(string: arguments[2]), fixture.scheme == "http",
              fixture.host == "127.0.0.1", fixture.port != nil else {
            throw NSError(domain: "DesktopPages", code: 1)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        let (data, _) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!)
        let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var pages: [[String: Any]] = []
        for target in targets where target["type"] as? String == "page" {
            guard let address = target["url"] as? String, address.hasPrefix(arguments[2] + "/"),
                  let endpoint = target["webSocketDebuggerUrl"] as? String,
                  let socketURL = URL(string: endpoint), socketURL.host == "127.0.0.1", socketURL.port == Int(port) else { continue }
            let socket = session.webSocketTask(with: socketURL)
            socket.resume()
            let deadline = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
            }
            defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
            // Fixed expression, only on this run's synthetic loopback pages.
            // No renderer input, navigation, clicks or app callbacks are used.
            let request: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": [
                "expression": "({url:location.href,title:document.title,heading:document.querySelector('h1')?.textContent||'',ready:document.readyState})",
                "returnByValue": true
            ]]
            let payload = try JSONSerialization.data(withJSONObject: request)
            try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
            for _ in 0..<32 {
                let message = try await socket.receive()
                let response: Data
                switch message {
                case .string(let text): response = Data(text.utf8)
                case .data(let bytes): response = bytes
                @unknown default: continue
                }
                guard let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any], reply["id"] as? Int == 1 else { continue }
                guard let result = reply["result"] as? [String: Any], let value = result["result"] as? [String: Any],
                      var page = value["value"] as? [String: Any] else { throw NSError(domain: "DesktopPages", code: 2) }
                page["targetID"] = target["id"]
                pages.append(page)
                break
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: pages, options: [.sortedKeys]))
        session.invalidateAndCancel()
    }
}
