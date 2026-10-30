import Foundation

/// Shared by the browser and native helper so their security flags cannot drift.
enum WorkBuddyInvocation {
    static let maximumImageBytes = 524_288
    static func arguments(prompt: String, model: String, instructions: String = "You are Kestrel’s assistant. Follow the user request and write British English.", hasImage: Bool = false, effort: String = "medium") -> [String] {
        let base = ["--print", "--output-format", "stream-json", "--system-prompt", instructions, "--model", model.isEmpty ? "deepseek-v4.1-flash" : model,
         "--effort", ["low", "medium", "high"].contains(effort) ? effort : "medium", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
         "--no-session-persistence", "--max-turns", "1", "--setting-sources", ""]
        return base + (hasImage ? ["--input-format", "stream-json"] : ["--", prompt])
    }
    static func imageInput(prompt: String, image: Data) throws -> Data {
        guard !image.isEmpty, image.count <= maximumImageBytes else {
            throw NSError(domain: "KestrelWorkBuddy", code: 1, userInfo: [NSLocalizedDescriptionKey: "The page image exceeded its request limit."])
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "text", "text": prompt],
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]]
        ]]]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        return data
    }
}

#if os(macOS)
import Foundation
import Security
import Darwin

@objc protocol KestrelCodexBridgeProtocol {
    func ready(withReply reply: @escaping () -> Void)
    func launch(arguments: [String], withReply reply: @escaping (String?) -> Void)
    func write(_ data: Data, withReply reply: @escaping (String?) -> Void)
    func read(withReply reply: @escaping (Data?, String?) -> Void)
    func respondWorkBuddy(executablePath: String, model: String, instructions: String, prompt: String, imageData: Data?, reasoningEffort: String, withReply reply: @escaping (Data?, Int32, String?) -> Void)
    func stop()
}

enum CodexBridgeIdentity {
    static let serviceName = "com.shayprasad.Kestrel.CodexAgent"
    static let agentPlist = serviceName + ".plist"
    static var currentExecutableURL: URL {
        var length: UInt32 = 0
        _NSGetExecutablePath(nil, &length)
        var bytes = [CChar](repeating: 0, count: Int(length))
        _NSGetExecutablePath(&bytes, &length)
        return URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
    }

    /// Distribution signatures retain their designated requirement; ad-hoc
    /// builds use their exact code hash. A different local app cannot claim
    /// this service merely by adopting Kestrel's bundle identifier.
    static func requirement(for url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw NSError(domain: "KestrelCodexBridge", code: 1)
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw NSError(domain: "KestrelCodexBridge", code: 2)
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw NSError(domain: "KestrelCodexBridge", code: 3)
        }
        return text as String
    }
}
#endif
