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

    public init(home: String, deleter: SafeDeleter) {
        self.home = home
        self.deleter = deleter
        self.finder = LeftoverFinder(home: home)
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
        let userPaths = finder.userFiles(bundleID: app.bundleID, appName: app.name,
                                         executable: app.executable, appPath: app.path,
                                         allowNamePatterns: allowNames)
        let sysPaths = finder.systemFiles(bundleID: app.bundleID, appName: app.name)

        var plan = UninstallPlan(app: app,
                                 bundleItem: LeftoverItem(path: app.path, size: app.size,
                                                          identity: app.identity,
                                                          requiresAdmin: false, sensitive: false),
                                 leftovers: [], skipped: [])

        // dedupe by resolved dev:inode — case-insensitive FS can surface the same object
        // under several spellings ("Sourcetree" vs "sourcetree"), like Mole's path dedupe
        var seen = Set<FileID>()
        let all = Self.filterNested(Set(userPaths + sysPaths)).filter { p in
            guard let id = FileStat.statID(p) else { return false }
            return seen.insert(id).inserted
        }
        var accepted: [String] = []
        for path in all {
            let admin = !path.hasPrefix(home + "/")
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
