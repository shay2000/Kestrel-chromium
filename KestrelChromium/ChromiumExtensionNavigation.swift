import Foundation

/// Only initial GET destinations can move from Chrome's install/onboarding
/// window into Kestrel. Never replay a form submission or cross profiles.
enum ChromiumExtensionNavigation {
    static func destination(_ url: URL?, method: String, usesDefaultProfile: Bool) -> URL? {
        guard usesDefaultProfile, method == "GET", let url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { return nil }
        if ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host?.isEmpty == false {
            return url
        }
        if let extensionURL = URLNormalisation.chromiumExtensionURL(from: url.absoluteString) { return extensionURL }
        return URLNormalisation.chromiumInternalURL(from: url.absoluteString)
    }
}
