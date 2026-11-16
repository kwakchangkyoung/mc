import Foundation

public enum Refusal: String, Sendable, Error {
    case emptyPath = "empty path"
    case notAbsolute = "not absolute"
    case parentTraversal = "path traversal"
    case controlCharacter = "control character"
    case criticalPath = "critical system path"
    case symlinkToCritical = "symlink to critical path"
    case ancestorSymlinkProtected = "ancestor symlink resolves to protected path"
    case activePowerlog = "active powerlog database"
    case liveUserCache = "live user cache"
    case sqliteInUse = "sqlite in use"
    case downloadInUse = "download in progress"
    case endpointSecurity = "endpoint security cache"
    case protected = "protected"
    case whitelist = "whitelist"
    case compiledModelCache = "compiled model cache"
    case identityChanged = "identity changed"
    case processRunning = "app running"
    case processUnknown = "process state unknown"
}

/// Live-state snapshots used by validation (replaces Mole's pgrep/ps/lsof probes).
public struct ProbeContext: Sendable {
    public let processes: ProcessSnapshot
    public let openFiles: OpenFilesSnapshot

    public init(processes: ProcessSnapshot, openFiles: OpenFilesSnapshot) {
        self.processes = processes
        self.openFiles = openFiles
    }

    public static func capture() -> ProbeContext {
        ProbeContext(processes: .capture(), openFiles: .capture())
    }
}

/// Port of Mole `validate_path_for_deletion` (file_ops.sh:1160-1379) and
/// `_mole_is_critical_deletion_path` (file_ops.sh:1044-1129).
public struct PathPolicy: Sendable {
    public let home: String
    public let protection: ProtectionPolicy

    public init(home: String, protection: ProtectionPolicy) {
        self.home = home
        self.protection = protection
    }

    // MARK: normalize (file_ops.sh:117-160)

    public static func normalize(_ path: String) -> String {
        var p = path
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        while p.contains("/./") { p = p.replacingOccurrences(of: "/./", with: "/") }
        while p.count > 1 && (p.hasSuffix("/.") || p.hasSuffix("/")) {
            p = p.hasSuffix("/.") ? String(p.dropLast(2)) : String(p.dropLast())
            if p.isEmpty { p = "/" }
        }
        let data = "/System/Volumes/Data/"
        if p.hasPrefix(data) {
            let rest = String(p.dropFirst(data.count))
            let top = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if !top.isEmpty, let a = FileStat.statID(data + top), let b = FileStat.statID("/" + top), a == b {
                p = "/" + rest
            }
        }
        return p
    }

    // MARK: critical deny list

    private static let criticalStringPatterns = [
        "/", "/bin", "/bin/*", "/dev", "/dev/*", "/sbin", "/sbin/*", "/usr", "/usr/*", "/System", "/System/*",
        "/Library", "/Library/Apple", "/Library/Apple/*", "/Library/Application Support",
        "/Library/Extensions", "/Library/Extensions/*", "/Library/Keychains", "/Library/Keychains/*",
        "/Applications", "/Applications/Finder.app", "/Applications/Finder.app/*",
        "/Applications/Safari.app", "/Applications/Safari.app/*",
        "/Volumes", "/opt", "/opt/homebrew", "/Users", "/Users/Shared", "/Users/Guest", "/Users/Guest/*",
        "/private", "/private/tmp", "/etc", "/etc/*", "/private/etc", "/private/etc/*",
        "/var", "/var/db", "/var/db/*", "/var/audit", "/var/audit/*", "/var/root",
        "/private/var", "/private/var/tmp", "/private/var/folders", "/private/var/db", "/private/var/db/*",
        "/private/var/audit", "/private/var/audit/*", "/private/var/root",
    ]
    private static let exactRoots = ["/", "/Applications", "/Library", "/Volumes", "/Network", "/cores", "/etc",
                                     "/home", "/net", "/tmp", "/var", "/private", "/private/tmp", "/private/var",
                                     "/private/var/tmp", "/private/var/folders", "/Users", "/opt", "/opt/homebrew"]
    private static let protectedTrees = ["/bin", "/dev", "/sbin", "/usr", "/System", "/private/etc",
                                         "/private/var/audit", "/private/var/db", "/private/var/root", "/Library/Apple",
                                         "/Library/Extensions", "/Library/Keychains", "/Applications/Finder.app",
                                         "/Applications/Safari.app"]

    public static func isCritical(_ path: String) -> Bool {
        if path.hasPrefix("/usr/local/") || path.hasPrefix("/opt/homebrew/") { return false }
        if criticalStringPatterns.contains(where: { Glob.match($0, path) }) { return true }
        // /Users/<name> (home roots)
        if path.hasPrefix("/Users/") && !path.dropFirst("/Users/".count).contains("/") { return true }

        if let id = FileStat.statID(path) {
            if exactRoots.contains(where: { FileStat.statID($0) == id }) { return true }
        }
        // any existing ancestor (or self) is the same file as a protected tree root (APFS case aliases)
        let treeIDs = Set(protectedTrees.compactMap { FileStat.statID($0) })
        var cursor = path
        while !cursor.isEmpty && cursor != "/" {
            if let id = FileStat.statID(cursor), treeIDs.contains(id) { return true }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        let parent = (path as NSString).deletingLastPathComponent
        if let pid = FileStat.statID(parent.isEmpty ? "/" : parent), pid == FileStat.statID("/Users") { return true }
        return false
    }

    /// Roots an uninstall leftover may never equal (Mole app_protection.sh:1560-1580):
    /// the Library roots, shared state roots, XDG dirs and $HOME itself.
    static func uninstallRoots(home: String) -> Set<String> {
        let lib = home + "/Library"
        return [
            home, lib, lib + "/Application Support", lib + "/Caches", lib + "/Logs",
            lib + "/Preferences", lib + "/Preferences/ByHost", lib + "/Containers",
            lib + "/WebKit", lib + "/HTTPStorages", lib + "/Application Scripts",
            lib + "/Autosave Information", lib + "/Group Containers",
            home + "/.config", home + "/.cache", home + "/.local/share",
        ]
    }

    private static let privateAllowPatterns = [
        "/private/tmp/*", "/private/var/tmp/*", "/private/var/log", "/private/var/log/*", "/private/var/folders/*",
        "/private/var/db/diagnostics", "/private/var/db/diagnostics/*",
        "/private/var/db/DiagnosticPipeline", "/private/var/db/DiagnosticPipeline/*",
        "/private/var/db/powerlog", "/private/var/db/powerlog/*",
        "/private/var/db/reportmemoryexception", "/private/var/db/reportmemoryexception/*",
        "/private/var/db/receipts/*.bom", "/private/var/db/receipts/*.plist",
    ]

    // MARK: validate

    /// Returns nil when the path may be deleted.
    /// `uninstall` selects Mole `MOLE_UNINSTALL_MODE` protection rules (system-critical only).
    public func validate(_ rawPath: String, probes: ProbeContext, uninstall: Bool = false) -> Refusal? {
        if rawPath.isEmpty { return .emptyPath }
        if !rawPath.hasPrefix("/") { return .notAbsolute }
        if rawPath.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return .parentTraversal }
        if rawPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .controlCharacter
        }
        let path = Self.normalize(rawPath)

        // Mole app_protection.sh: a leftover may never BE a Library/shared root itself
        if uninstall, Self.uninstallRoots(home: home).contains(path) { return .protected }

        // leaf symlink: its target must not be critical (only the link itself is ever removed)
        if FileStat.isSymlink(path), let dest = FileStat.readLink(path) {
            let abs = dest.hasPrefix("/") ? dest : ((path as NSString).deletingLastPathComponent + "/" + dest)
            if Self.isCritical(Self.normalize(abs)) { return .symlinkToCritical }
        }

        // ancestor symlink: re-check the physical path (refusal only)
        let parent = (path as NSString).deletingLastPathComponent
        if hasSymlinkAncestor(parent), let physicalParent = FileStat.realPath(parent) {
            let physical = Self.normalize(physicalParent + "/" + (path as NSString).lastPathComponent)
            if Self.isCritical(physical) || protection.shouldProtectPath(physical) { return .ancestorSymlinkProtected }
        }

        if path == "/System/Library/Caches/com.apple.coresymbolicationd/data"
            || path.hasPrefix("/System/Library/Caches/com.apple.coresymbolicationd/data/") {
            return nil
        }

        if Glob.match("/private/var/db/powerlog/Library/PerfPowerTelemetry/*/Current*", path) { return .activePowerlog }

        if let refusal = liveUserCacheRefusal(path, probes: probes) { return refusal }

        if Self.isSQLiteFamily(path) && probes.openFiles.state(under: Self.sqliteBase(path)) != .notRunning {
            return .sqliteInUse
        }

        if isDownloadInProgressCandidate(path) && probes.openFiles.state(under: path) != .notRunning {
            return .downloadInUse
        }

        if ProtectionPolicy.isEndpointSecurityCachePath(path) { return .endpointSecurity }

        if Glob.matchesAny(Self.privateAllowPatterns, path) { return nil }

        if Self.isCritical(path) { return .criticalPath }

        // ~/.Trash/<top> skips protection; everything else goes through should_protect_path
        let trash = home + "/.Trash/"
        let isTrashTop = path.hasPrefix(trash) && !path.dropFirst(trash.count).contains("/")
        if !isTrashTop && protection.shouldProtectPath(path, uninstall: uninstall) { return .protected }
        return nil
    }

    private func hasSymlinkAncestor(_ start: String) -> Bool {
        var cursor = start
        while !cursor.isEmpty && cursor != "/" {
            // /tmp, /var, /etc are system symlinks into /private; Mole's checks treat them via /private forms.
            if FileStat.isSymlink(cursor) { return true }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        return false
    }

    // MARK: live user cache (file_ops.sh:206-250, 904-1018)

    func userCacheScope(_ path: String) -> (owner: String, container: Bool)? {
        let lib = home + "/Library"
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        var component = ""
        var container = false
        if p.hasPrefix(lib + "/Caches/") {
            component = String(p.dropFirst((lib + "/Caches/").count).split(separator: "/").first ?? "")
        } else if p.hasPrefix(lib + "/Containers/") {
            let rest = String(p.dropFirst((lib + "/Containers/").count))
            component = String(rest.split(separator: "/").first ?? "")
            let suffix = String(rest.dropFirst(component.count))
            guard suffix == "/Data/Library/Caches" || suffix.hasPrefix("/Data/Library/Caches/") else { return nil }
            container = true
        } else if p.hasPrefix(lib + "/Group Containers/") {
            let rest = String(p.dropFirst((lib + "/Group Containers/").count))
            component = String(rest.split(separator: "/").first ?? "")
            let suffix = String(rest.dropFirst(component.count))
            guard ["/Caches", "/Library/Caches"].contains(where: { suffix == $0 || suffix.hasPrefix($0 + "/") })
            else { return nil }
            container = true
        } else {
            return nil
        }
        guard component.contains("."), !component.hasPrefix(".") else { return nil }
        return (component, container)
    }

    private func liveUserCacheRefusal(_ path: String, probes: ProbeContext) -> Refusal? {
        guard let scope = userCacheScope(path) else { return nil }
        switch probes.processes.cacheOwnerState(scope.owner) {
        case .running: return .liveUserCache
        case .unknown: return .liveUserCache
        case .notRunning: break
        }
        if scope.container {
            if probes.openFiles.state(under: path) != .notRunning { return .liveUserCache }
        } else if Self.isSQLiteFamily(path) {
            if probes.openFiles.state(under: Self.sqliteBase(path)) != .notRunning { return .liveUserCache }
        } else if FileStat.isDirectory(path) {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for child in children where Self.isSQLiteFamily(child) {
                let full = path + "/" + child
                if probes.openFiles.state(under: Self.sqliteBase(full)) != .notRunning { return .liveUserCache }
            }
        }
        return nil
    }

    static func isSQLiteFamily(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".db", ".sqlite", ".sqlite3"].contains { ext in
            lower.hasSuffix(ext) || ["-wal", "-shm", "-journal"].contains { lower.hasSuffix(ext + $0) }
        }
    }

    static func sqliteBase(_ path: String) -> String {
        for suffix in ["-wal", "-shm", "-journal"] where path.lowercased().hasSuffix(suffix) {
            return String(path.dropLast(suffix.count))
        }
        return path
    }

    private func isDownloadInProgressCandidate(_ path: String) -> Bool {
        let downloads = home + "/Downloads/"
        if path.hasPrefix(downloads) && !path.dropFirst(downloads.count).contains("/") {
            return [".download", ".crdownload", ".part"].contains { path.hasSuffix($0) }
        }
        let brew = home + "/Library/Caches/Homebrew/downloads/"
        return path.hasPrefix(brew) && path.hasSuffix(".incomplete")
    }
}
