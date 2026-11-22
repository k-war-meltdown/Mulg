import Foundation

/// A card path pattern: `*` matches within one folder, `**` across folders, `?` one character.
struct Glob {
    let pattern: String
    private let expression: NSRegularExpression

    init(_ pattern: String) throws {
        self.pattern = pattern
        expression = try NSRegularExpression(pattern: Self.regularExpression(for: pattern))
    }

    func matches(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return expression.firstMatch(in: path, options: [], range: range) != nil
    }

    static func regularExpression(for pattern: String) -> String {
        var result = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let rest = pattern[index...]
            if rest.hasPrefix("**/") {
                result += "(?:.*/)?"
                index = pattern.index(index, offsetBy: 3)
            } else if rest.hasPrefix("**") {
                result += ".*"
                index = pattern.index(index, offsetBy: 2)
            } else {
                let character = pattern[index]
                switch character {
                case "*": result += "[^/]*"
                case "?": result += "[^/]"
                default: result += NSRegularExpression.escapedPattern(for: String(character))
                }
                index = pattern.index(after: index)
            }
        }
        return result + "$"
    }
}
