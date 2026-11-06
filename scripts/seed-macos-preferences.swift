// Disposable-runner setup using the same Foundation preferences types as the app.
import Foundation

guard CommandLine.arguments.count == 3,
      let defaults = UserDefaults(suiteName: CommandLine.arguments[1]) else { exit(2) }
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard data.count <= 1_000_000,
      let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      values.keys.allSatisfy({ $0.hasPrefix("kestrel.") }) else { exit(2) }
for (key, value) in values { defaults.set(value, forKey: key) }
guard defaults.synchronize() else { exit(1) }
print("Seeded \(values.count) synthetic Kestrel preference keys through Foundation")
