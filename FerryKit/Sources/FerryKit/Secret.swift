import Foundation

/// A text that looks like a code or a password (docs/protocol.md › Codes and passwords): no notification shows it, and
/// the box keeps it 15 minutes, or until it is copied. bin/ferry's `looks_secret()` is the same rule; both run the
/// vectors in Tests/FerryKitTests/Fixtures/secrets.json.
public enum Secret {
    /// What a notification says in its place
    public static let hidden = "\(named) · open to see"
    /// What a notification says of one already on the clipboard, with nothing more to open
    public static let named = "Code or password"
    /// How long the box keeps one
    public static let keep: TimeInterval = 15 * 60

    /// A code (4 to 8 digits, maybe in groups: "123 456"), or one word of 6 to 256 characters that mixes letters,
    /// digits and other characters and isn't a number, an address, a path or words joined by hyphens. Counted in
    /// Unicode scalars, as Python counts; whitespace is Unicode's White_Space.
    public static func looksLike(_ text: String) -> Bool {
        var scalars = Substring(text).unicodeScalars[...]
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        let t = String(String.UnicodeScalarView(scalars))
        if scalars.allSatisfy({ isDigit($0) || " ()+-".unicodeScalars.contains($0) }) {
            // A code, or a number (a phone number) that isn't one
            let groups = t.split(omittingEmptySubsequences: false) { $0 == " " || $0 == "-" }
            guard groups.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(isDigit) }) else { return false }
            return (4...8).contains(scalars.filter(isDigit).count)
        }
        guard (6...256).contains(scalars.count), !scalars.contains(where: \.properties.isWhitespace) else { return false }
        // Scalar by scalar, as Python compares: "/" and a combining mark after it are one Character
        let u = Array(scalars)
        func starts(_ s: String) -> Bool { u.starts(with: s.unicodeScalars) }
        func has(_ s: String) -> Bool {
            let n = Array(s.unicodeScalars)
            return u.count >= n.count && (0...(u.count - n.count)).contains { Array(u[$0..<$0 + n.count]) == n }
        }
        let address = /[^@]+@[^@]+\.[A-Za-z]{2,}/.matchingSemantics(.unicodeScalar)
        let host = /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(\/.*)?/.matchingSemantics(.unicodeScalar)
        if has("://") || String(String.UnicodeScalarView(u.prefix(4))).lowercased() == "www." || starts("/") || starts("~/")
            || t.wholeMatch(of: address) != nil || t.wholeMatch(of: host) != nil {   // a host (a file) name
            return false
        }
        if let first = scalars.first, let last = scalars.last, isLetter(first), isLetter(last),
           scalars.allSatisfy({ isLetter($0) || "-'\u{2019}".unicodeScalars.contains($0) }) {   // well-known
            return false
        }
        let kinds = Set(scalars.map { isLetter($0) ? 0 : isDigit($0) ? 1 : 2 })
        return kinds.count >= 2
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool { ("0"..."9").contains(s) }

    /// Python's str.isalpha(): the letter categories
    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }
}
