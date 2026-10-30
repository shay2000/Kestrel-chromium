import Foundation

/// Turns a Swift string into a safe JavaScript string literal, including the
/// surrounding double quotes. Model text is only ever embedded into fixed page
/// scripts through this function, so a query cannot break out of its literal or
/// inject statements. It also escapes the JavaScript line separators U+2028 and
/// U+2029, which are valid in JSON but terminate string literals in older
/// JavaScript engines.
enum JavaScriptStringLiteral {
    static func escape(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case "\u{2028}": result += "\\u2028"
            case "\u{2029}": result += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
