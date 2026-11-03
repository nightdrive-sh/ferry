import Foundation

/// How long ago, as Ferry's page says it (`ago()` in the PWA): "now", "12 min", "3 h", "2 d".
public enum Age {
    public static func short(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86400)) d"
    }

    /// How long a send that waits for its computer has before it is dropped: "3 d left", "47 h left", "12 min
    /// left" (look.py's `left()`). Days are rounded, so a send just made has 3, not 2.
    public static func left(_ seconds: TimeInterval) -> String {
        if seconds >= 2 * 86400 { return "\(Int((seconds / 86400).rounded())) d left" }
        if seconds >= 3600 { return "\(Int(seconds / 3600)) h left" }
        return "\(max(Int(seconds / 60), 1)) min left"
    }
}

/// A file's size, 1000-based as the page shows it: "240 B", "5.7 MB".
public enum ByteSize {
    public static func format(_ bytes: Int64) -> String {
        if bytes < 1000 { return "\(bytes) B" }
        var n = Double(bytes)
        for unit in ["KB", "MB", "GB"] {
            n /= 1000
            if n < 1000 || unit == "GB" { return String(format: "%.1f %@", n, unit) }
        }
        return "\(bytes) B"   // not reached: GB always returns
    }
}
