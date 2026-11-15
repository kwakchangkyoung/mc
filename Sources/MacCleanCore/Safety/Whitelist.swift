import Foundation

/// Port of Mole whitelist (`lib/core/base.sh:469`, `is_path_whitelisted` app_protection.sh:684).
/// File format is Mole-compatible: one pattern per line, `#` comments, leading `~` / `$HOME`.
public struct Whitelist: Sendable {
    public static let finderMetadataToken = "FINDER_METADATA"

    public static let defaultPatterns = [
        "~/Library/Caches/ms-playwright*", "~/Library/Caches/camoufox*", "~/Library/Caches/Cypress*",
        "~/.gradle/caches/*", "~/.gradle/daemon/*", "~/.ollama/models/*",
        "~/Library/Caches/com.nssurge.surge-mac/*", "~/Library/Application Support/com.nssurge.surge-mac/*",
        "~/Library/Caches/org.R-project.R/R/renv/*",
        "~/Library/Caches/JetBrains*", "~/Library/Caches/com.jetbrains.toolbox*",
        "~/Library/Caches/tealdeer/tldr-pages", "~/Library/Application Support/JetBrains*",
        "~/Library/Caches/com.apple.finder", "~/Library/Mobile Documents*", finderMetadataToken,
    ]

    /// Always merged, even when the user file replaces the defaults.
    public static let safetyPatterns = [
        finderMetadataToken,
        "~/Library/Caches/com.apple.FontRegistry*", "~/Library/Caches/com.apple.spotlight*",
        "~/Library/Caches/com.apple.Spotlight*", "~/Library/Caches/CloudKit*", "~/Library/Caches/kitty",
        "~/Library/Caches/pypoetry/virtualenvs*", "~/Library/Caches/pnpm/dlx*", "~/Library/Caches/llama.cpp",
        "~/Library/Caches/org.R-project.R/R/renv/*",
    ]

    private static let rejectedPatterns = ["/", "/System", "/System/*", "/bin", "/bin/*", "/sbin", "/sbin/*",
                                           "/usr/bin", "/usr/bin/*", "/usr/sbin", "/usr/sbin/*", "/etc", "/etc/*",
                                           "/var/db", "/var/db/*"]

    public enum LoadError: Error, Equatable { case unreadable(String) }

    public let patterns: [String]        // expanded, absolute (plus tokens)
    public let rejected: [String]        // invalid lines (shown as warnings)
    public var protectsFinderMetadata: Bool { patterns.contains(Self.finderMetadataToken) }

    public init(expandedPatterns: [String], rejected: [String] = []) {
        self.patterns = expandedPatterns
        self.rejected = rejected
    }

    /// Fail-closed load: an existing but unreadable file throws (Mole aborts the command).
    public static func load(file: URL, home: String) throws -> Whitelist {
        var raw: [String]
        if FileStat.exists(file.path) {
            guard FileStat.isDirectory(file.path) == false,
                  let text = try? String(contentsOf: file, encoding: .utf8) else {
                throw LoadError.unreadable(file.path)
            }
            raw = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        } else {
            raw = defaultPatterns
        }
        for s in safetyPatterns where !raw.contains(s) { raw.append(s) }

        var accepted: [String] = []
        var rejected: [String] = []
        for line in raw {
            if line == finderMetadataToken { accepted.append(line); continue }
            let p = expand(line, home: home)
            let invalid = p.contains("..") || p.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                || !p.hasPrefix("/") || p.contains("//") || rejectedPatterns.contains(p)
            if invalid { rejected.append(line) } else if !accepted.contains(p) { accepted.append(p) }
        }
        return Whitelist(expandedPatterns: accepted, rejected: rejected)
    }

    public static func expand(_ pattern: String, home: String) -> String {
        for prefix in ["~", "${HOME}", "$HOME"] where pattern == prefix || pattern.hasPrefix(prefix + "/") {
            return home + pattern.dropFirst(prefix.count)
        }
        return pattern
    }

    public func contains(_ target: String) -> Bool {
        let t = Self.trim(target)
        for pattern in patterns where pattern != Self.finderMetadataToken {
            let p = Self.trim(pattern)
            if t == p || Glob.match(p, t) { return true }
            if p.hasPrefix(t + "/") { return true }   // protected child → keep parent
            if !Glob.hasMeta(p) && t.hasPrefix(p + "/") { return true }
        }
        return false
    }

    private static func trim(_ s: String) -> String {
        var r = s
        while r.contains("//") { r = r.replacingOccurrences(of: "//", with: "/") }
        if r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        return r
    }
}
