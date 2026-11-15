import Darwin

/// Bash `[[ str == pattern ]]` semantics: `*` also crosses `/` (fnmatch without FNM_PATHNAME).
public enum Glob {
    public static func match(_ pattern: String, _ string: String) -> Bool {
        fnmatch(pattern, string, 0) == 0
    }

    public static func hasMeta(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
    }

    public static func matchesAny(_ patterns: [String], _ string: String) -> Bool {
        patterns.contains { !$0.isEmpty && match($0, string) }
    }
}
