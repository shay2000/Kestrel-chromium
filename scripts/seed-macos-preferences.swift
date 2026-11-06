// Disposable-runner setup using the same Foundation preferences types as the app.
import Foundation

guard [3, 4].contains(CommandLine.arguments.count),
      let defaults = UserDefaults(suiteName: CommandLine.arguments[1]) else { exit(2) }
if CommandLine.arguments.count == 4 {
    guard CommandLine.arguments[2] == "--export" else { exit(2) }
    let values = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("kestrel.") }
    let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    exit(0)
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard data.count <= 1_000_000,
      let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      values.keys.allSatisfy({ $0.hasPrefix("kestrel.") }) else { exit(2) }
for (key, value) in values { defaults.set(value, forKey: key) }
guard defaults.synchronize() else { exit(1) }
print("Seeded \(values.count) synthetic Kestrel preference keys through Foundation")
