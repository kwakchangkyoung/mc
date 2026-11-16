import Foundation

/// One removable path in an uninstall plan (the app bundle or a leftover).
public struct LeftoverItem: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let size: SizeResult
    /// dev:inode bound at scan time; re-checked by SafeDeleter before any move to Trash.
    public let identity: PathIdentity
    /// /Library system-domain item: listed for review but not deletable without admin rights.
    public let requiresAdmin: Bool
    /// Credentials/secrets-style names (Mole `has_sensitive_data`, display only).
    public let sensitive: Bool
}

public struct UninstallPlan: Sendable {
    public let app: InstalledApp
    /// The .app bundle itself — always part of an uninstall.
    public let bundleItem: LeftoverItem
    /// User-domain leftovers that passed the same checks a real delete uses.
    public var leftovers: [LeftoverItem]
    /// Candidates refused by the safety layer at scan time (dry-run semantics).
    public var skipped: [(path: String, reason: Refusal)]
}

public struct UninstallResult: Sendable {
    public var removedBytes: Int64 = 0
    public var removedCount = 0
    public var skipped: [(path: String, reason: String)] = []
    public var failed: [(path: String, message: String)] = []
}

public enum UninstallError: Error, Equatable {
    case appRunning(String)
    case processStateUnknown
    case officialUninstallerRequired(String)
}

/// Builds an uninstall plan (app bundle + leftovers) and executes it through SafeDeleter.
/// Everything is moved to Trash; there is no permanent-delete fallback (DESIGN principle 2).
public struct UninstallEngine: Sendable {
    public let home: String
    public let deleter: SafeDeleter
    public let finder: LeftoverFinder
    /// User-domain roots besides $HOME: the Darwin per-user cache/temp dirs
    /// (/var/folders/.../C, .../T) hold per-user app data even though they live outside ~.
    public let userRoots: [String]

    public init(home: String, deleter: SafeDeleter, userRoots: [String]? = nil) {
        self.home = home
        self.deleter = deleter
        self.finder = LeftoverFinder(home: home)
        self.userRoots = userRoots
            ?? [DarwinDirs.userCacheDir(), DarwinDirs.userTempDir()].compactMap { $0 }
    }

    /// Sibling guard (Mole `uninstall` family ownership): another installed app sharing the
    /// bundle id or the channel-stripped name means name-based matching is unsafe.
    public static func siblings(of app: InstalledApp, in all: [InstalledApp]) -> [InstalledApp] {
        all.filter {
            $0.path != app.path
                && ($0.bundleID.lowercased() == app.bundleID.lowercased()
                    || LeftoverFinder.baseName($0.name) == LeftoverFinder.baseName(app.name))
        }
    }

    public func plan(for app: InstalledApp, siblings: [InstalledApp], probes: ProbeContext,
                     sizeDeadline: Date = Date().addingTimeInterval(30)) -> UninstallPlan {
        let allowNames = siblings.isEmpty
        let siblingIDs = siblings.map(\.bundleID)
        let userPaths = finder.userFiles(bundleID: app.bundleID, appName: app.name,
                                         executable: app.executable, appPath: app.path,
                                         allowNamePatterns: allowNames,
                                         siblingBundleIDs: siblingIDs)
        let sysPaths = finder.systemFiles(bundleID: app.bundleID, appName: app.name,
                                          siblingBundleIDs: siblingIDs)

        var plan = UninstallPlan(app: app,
                                 bundleItem: LeftoverItem(path: app.path, size: app.size,
                                                          identity: app.identity,
                                                          requiresAdmin: false, sensitive: false),
                                 leftovers: [], skipped: [])

        // dedupe by lstat dev:inode — case-insensitive FS can surface the same object
        // under several spellings ("Sourcetree" vs "sourcetree"), like Mole's path dedupe.
        // lstat (not stat): a dangling link must not vanish, and a symlink must not
        // shadow its target
        var seen = Set<FileID>()
        let all = Self.filterNested(Set(userPaths + sysPaths)).filter { p in
            guard let id = FileStat.lstatID(p) else { return false }
            return seen.insert(id).inserted
        }
        var accepted: [String] = []
        for path in all {
            let admin = !isUserDomain(path)
            if admin {
                plan.leftovers.append(LeftoverItem(path: path, size: .zero,
                                                   identity: PathIdentity.capture(path),
                                                   requiresAdmin: true, sensitive: false))
            } else if let refusal = deleter.check(path, probes: probes, forUninstall: true) {
                plan.skipped.append((path, refusal))
            } else {
                accepted.append(path)
            }
        }

        var sizes = [SizeResult](repeating: .zero, count: accepted.count)
        sizes.withUnsafeMutableBufferPointer { buf in
            let s = buf
            DispatchQueue.concurrentPerform(iterations: accepted.count) { i in
                s[i] = SizeCalculator.allocatedSize(of: accepted[i], deadline: sizeDeadline)
            }
        }
        var items = accepted.enumerated().map { (i, path) in
            LeftoverItem(path: path, size: sizes[i], identity: PathIdentity.capture(path),
                         requiresAdmin: false, sensitive: Self.isSensitive(path))
        }
        items.sort { $0.size.bytes > $1.size.bytes }
        plan.leftovers.append(contentsOf: items)
        return plan
    }

    /// Move the app bundle and the chosen leftovers to Trash. Refuses when the app is running
    /// (or its state cannot be determined) and when an official uninstaller is required.
    public func execute(app: InstalledApp, items: [LeftoverItem],
                        probes: ProbeContext) throws -> UninstallResult {
        if let vendor = app.officialUninstaller { throw UninstallError.officialUninstallerRequired(vendor) }
        var names: [String] = []
        if let exec = app.executable { names.append(exec) }
        switch probes.processes.state(bundleIDs: [app.bundleID], names: names) {
        case .running: throw UninstallError.appRunning(app.name)
        case .unknown: throw UninstallError.processStateUnknown
        case .notRunning: break
        }
        // a process whose executable lives inside the bundle counts as running too
        // (helpers/agents the bundle id and main-executable checks miss)
        if probes.processes.entries.contains(where: {
            !$0.path.isEmpty && $0.path.hasPrefix(app.path + "/")
        }) { throw UninstallError.appRunning(app.name) }

        var result = UninstallResult()
        for item in items where !item.requiresAdmin {
            switch deleter.trash(item.path, expected: item.identity, probes: probes,
                                 forUninstall: true) {
            case .removed(let size):
                result.removedBytes += size.bytes
                result.removedCount += 1
            case .missing:
                break
            case .skipped(let r):
                result.skipped.append((item.path, r.rawValue))
            case .failed(let message):
                result.failed.append((item.path, message))
            case .wouldRemove:
                break
            }
        }
        return result
    }

    // MARK: helpers

    /// $HOME and the Darwin per-user dirs are user domain; anything else needs admin rights.
    func isUserDomain(_ path: String) -> Bool {
        path.hasPrefix(home + "/")
            || userRoots.contains { path.hasPrefix($0) }
    }

    /// Mole `mole_filter_nested_paths`: keep only the topmost path of nested candidates.
    static func filterNested(_ paths: Set<String>) -> [String] {
        paths.filter { p in
            var parent = (p as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if paths.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }

    private static let sensitiveTokens = [
        ".ssh", ".gnupg", ".aws", ".kube", "cookies", "password", "credentials",
        "secrets", "accounts", "user data",
    ]

    static func isSensitive(_ path: String) -> Bool {
        let lower = path.lowercased()
        return sensitiveTokens.contains { lower.contains($0) }
    }
}
