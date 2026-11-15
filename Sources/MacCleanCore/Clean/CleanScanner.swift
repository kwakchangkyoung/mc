import Darwin
import Foundation

public struct CleanItem: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let ruleID: String
    public let size: SizeResult
    public let identity: PathIdentity

    public static func == (a: CleanItem, b: CleanItem) -> Bool { a.path == b.path }
    public func hash(into h: inout Hasher) { h.combine(path) }
}

public struct CleanGroup: Sendable, Identifiable {
    public var id: String { rule.id }
    public let rule: CleanRule
    public var items: [CleanItem]
    public var skipped: [(path: String, reason: Refusal)]
    /// Set when the whole rule was deferred (guarded app running or state unknown).
    public var deferred: Refusal?

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size.bytes } }
    public var partial: Bool { items.contains { $0.size.partial } }
}

public struct CleanScanResult: Sendable {
    public var groups: [CleanGroup]
    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
}

public struct CleanExecutionResult: Sendable {
    public var removedBytes: Int64 = 0
    public var removedCount = 0
    public var skipped: [(path: String, reason: String)] = []
    public var failed: [(path: String, message: String)] = []
}

/// Expands catalog rules into candidates, runs every candidate through the same checks a real
/// delete uses (dry-run semantics), and later executes a user-selected subset.
public struct CleanEngine: Sendable {
    public let home: String
    public let deleter: SafeDeleter
    public let rules: [CleanRule]

    public init(home: String, deleter: SafeDeleter, rules: [CleanRule] = CleanCatalog.rules) {
        self.home = home
        self.deleter = deleter
        self.rules = rules
    }

    // MARK: scan

    public func scan(sizeBudget: TimeInterval = 30) -> CleanScanResult {
        let probes = ProbeContext.capture()
        var claimed = Set<String>()
        var groups: [CleanGroup] = []
        var pending: [(groupIndex: Int, path: String)] = []

        for rule in rules {
            var group = CleanGroup(rule: rule, items: [], skipped: [], deferred: nil)
            if let g = rule.whenNotRunning {
                switch probes.processes.state(bundleIDs: g.bundleIDs, names: g.names) {
                case .running: group.deferred = .processRunning
                case .unknown: group.deferred = .processUnknown
                case .notRunning: break
                }
            }
            if group.deferred == nil {
                for path in candidates(for: rule) where claimed.insert(path).inserted {
                    if let refusal = deleter.check(path, probes: probes) {
                        group.skipped.append((path, refusal))
                    } else {
                        pending.append((groups.count, path))
                    }
                }
            }
            groups.append(group)
        }

        // drop candidates nested inside another candidate (Mole normalize_paths_for_cleanup)
        let allPaths = Set(pending.map(\.path))
        pending.removeAll { entry in
            var parent = (entry.path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if allPaths.contains(parent) { return true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }

        let deadline = Date().addingTimeInterval(sizeBudget)
        var sizes = [SizeResult](repeating: .zero, count: pending.count)
        var identities = [PathIdentity](repeating: PathIdentity(parent: nil, target: nil), count: pending.count)
        sizes.withUnsafeMutableBufferPointer { sizeBuf in
            identities.withUnsafeMutableBufferPointer { idBuf in
                let s = sizeBuf
                let ids = idBuf
                DispatchQueue.concurrentPerform(iterations: pending.count) { i in
                    ids[i] = PathIdentity.capture(pending[i].path)
                    s[i] = SizeCalculator.allocatedSize(of: pending[i].path, deadline: deadline)
                }
            }
        }
        for (i, entry) in pending.enumerated() {
            let rule = groups[entry.groupIndex].rule
            groups[entry.groupIndex].items.append(
                CleanItem(path: entry.path, ruleID: rule.id, size: sizes[i], identity: identities[i]))
        }
        for i in groups.indices { groups[i].items.sort { $0.size.bytes > $1.size.bytes } }
        return CleanScanResult(groups: groups)
    }

    // MARK: execute

    public func execute(_ items: [CleanItem], rulesByID: [String: CleanRule]? = nil) -> CleanExecutionResult {
        let probes = ProbeContext.capture()   // fresh state right before deleting
        let lookup = rulesByID ?? Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        var result = CleanExecutionResult()
        var guardCache: [String: ProbeState] = [:]
        for item in items {
            if let rule = lookup[item.ruleID], let g = rule.whenNotRunning {
                let state = guardCache[rule.id] ?? probes.processes.state(bundleIDs: g.bundleIDs, names: g.names)
                guardCache[rule.id] = state
                if state != .notRunning {
                    result.skipped.append((item.path, state == .running ? Refusal.processRunning.rawValue
                                                                          : Refusal.processUnknown.rawValue))
                    continue
                }
            }
            switch deleter.remove(item.path, expected: item.identity, dryRun: false, probes: probes) {
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

    // MARK: candidate expansion

    func candidates(for rule: CleanRule) -> [String] {
        var out: [String] = []
        let minAge = rule.minAgeDays.map { Date().addingTimeInterval(-$0 * 86_400) }
        for pattern in rule.patterns {
            for path in Self.expand(Whitelist.expand(pattern, home: home)) {
                let name = (path as NSString).lastPathComponent
                if rule.excludeNames.contains(name) { continue }
                if let minAge, let mtime = FileStat.modificationDate(path), mtime > minAge { continue }
                if rule.skipProtectedContainerOwners, isProtectedContainerOwner(path) { continue }
                out.append(path)
            }
        }
        return out
    }

    private func isProtectedContainerOwner(_ path: String) -> Bool {
        guard let id = ProtectionPolicy.containerBundleID(path) else { return false }
        if id.hasPrefix("com.apple.") || id.hasPrefix("group.com.apple.") || id.hasPrefix("systemgroup.com.apple.") {
            return true
        }
        let critical = ["backgroundtaskmanagement", "loginitems", "systempreferences", "systemsettings", "settings",
                        "preferences", "controlcenter", "biometrickit", "sfl", "tcc"]
        let lower = id.lowercased()
        if critical.contains(where: { lower.contains($0) }) { return true }
        return deleter.policy.protection.shouldProtectData(id)
    }

    /// Bash-style pathname expansion (no dotfiles for `*`, like Mole without dotglob).
    static func expand(_ pattern: String) -> [String] {
        let components = pattern.split(separator: "/").map(String.init)
        var current = [""]
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            var next: [String] = []
            for base in current {
                let dir = base.isEmpty ? "/" : base
                if Glob.hasMeta(component) {
                    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                    for name in names.sorted() where fnmatch(component, name, FNM_PERIOD) == 0 {
                        let path = base + "/" + name
                        if isLast || isDirectoryFollowing(path) { next.append(path) }
                    }
                } else {
                    let path = base + "/" + component
                    if isLast ? FileStat.exists(path) : isDirectoryFollowing(path) { next.append(path) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    private static func isDirectoryFollowing(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
