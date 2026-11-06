import Foundation

/// Kestrel's preferences belong to its application identity even after an
/// embedded runtime has initialised Foundation's standard defaults instance.
enum KestrelPreferences {
    static let domain = "com.shayprasad.Kestrel"
    static let app = UserDefaults(suiteName: domain)!
}
