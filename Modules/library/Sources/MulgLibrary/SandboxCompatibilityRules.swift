import Foundation

/// Compatibility exceptions supplement App Sandbox. A bare deny of every file
/// operation also hides native bundle/volume state required by Foundation and Metal.
public enum SandboxCompatibilityRules {
    public static func preservingNativeFileAccess(_ rules: [String]) -> [String] {
        rules.filter { !isUnfilteredFileDenial($0) }
    }

    private static func isUnfilteredFileDenial(_ rule: String) -> Bool {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.first == "(", text.last == ")" else { return false }
        let words = text.dropFirst().dropLast().split(whereSeparator: { $0.isWhitespace })
        guard words.count > 1, words.first == "deny" else { return false }
        // Nested filters, paths, comments and non-file operations remain untouched.
        return words.dropFirst().allSatisfy { word in
            word.hasPrefix("file") && word.allSatisfy { character in
                character.isASCII && (character.isLetter || character == "-" || character == "*")
            }
        }
    }
}
