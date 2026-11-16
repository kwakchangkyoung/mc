import Darwin
import Foundation

/// Per-user Darwin dirs via confstr (`getconf DARWIN_USER_*_DIR`). The _CS constants are
/// not exported to Swift, so the unistd.h values are used: DIR=65536, TEMP=65537, CACHE=65538.
/// Returned paths keep the confstr spelling and end with "/".
public enum DarwinDirs {
    private static func conf(_ code: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard confstr(code, &buf, buf.count) > 0 else { return nil }
        let s = String(cString: buf)
        return s.hasSuffix("/") ? s : s + "/"
    }

    /// `/var/folders/xx/yy/` — parent of the per-user cache/temp dirs.
    public static func userDir() -> String? { conf(65536) }

    /// `/var/folders/xx/yy/T/` — `NSTemporaryDirectory()`'s underlying location.
    public static func userTempDir() -> String? { conf(65537) }

    /// `/var/folders/xx/yy/C/` — `getconf DARWIN_USER_CACHE_DIR`.
    public static func userCacheDir() -> String? { conf(65538) }
}
