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
    /// Optional per-scan explanation shown under the group (opt-in notes, fail-closed reasons).
    public var note: String?
    /// assetIDs in use by the current wallpaper configuration (aerial videos rule).
    public var inUseAssets: [String] = []

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
    /// Probe capture seam (tests); live state is re-read before each rule's deletions.
    public var captureProbes: @Sendable () -> ProbeContext

    public init(home: String, deleter: SafeDeleter, rules: [CleanRule] = CleanCatalog.rules,
                captureProbes: @escaping @Sendable () -> ProbeContext = { ProbeContext.capture() }) {
        self.home = home
        self.deleter = deleter
        self.rules = rules
        self.captureProbes = captureProbes
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
                if rule.allowance == .aerialVideos {
                    let aerial = AerialVideos.scan(home: home)
                    group.inUseAssets = aerial.inUseAssetIDs.sorted()
                    if let reason = aerial.unavailableReason {
                        group.note = "사용할 수 없습니다 — \(reason)"
                    } else {
                        for path in aerial.cleanable where claimed.insert(path).inserted {
                            if let refusal = deleter.check(path, probes: probes,
                                                           allowance: rule.allowance) {
                                group.skipped.append((path, refusal))
                            } else {
                                pending.append((groups.count, path))
                            }
                        }
                        for path in aerial.inUseFiles { group.skipped.append((path, .inUse)) }
                        var note = "사용 중인 영상은 제외합니다. 휴지통을 비워야 공간이 확보됩니다."
                        if aerial.shuffleOn {
                            note += " 순환(무작위) 설정이 켜져 있어 지운 영상을 macOS가 다시 내려받을 수 있습니다."
                        }
                        group.note = note
                    }
                } else {
                    for path in candidates(for: rule) where claimed.insert(path).inserted {
                        if let refusal = deleter.check(path, probes: probes) {
                            group.skipped.append((path, refusal))
                        } else {
                            pending.append((groups.count, path))
                        }
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
        let lookup = rulesByID ?? Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        var result = CleanExecutionResult()
        // group by rule so probes are re-captured right before each rule's deletions —
        // a guard that turned "running" after the scan must still block its items
        var order: [String] = []
        var byRule: [String: [CleanItem]] = [:]
        for item in items {
            if byRule[item.ruleID] == nil { order.append(item.ruleID) }
            byRule[item.ruleID, default: []].append(item)
        }
        for ruleID in order {
            let probes = captureProbes()
            let rule = lookup[ruleID]
            if let g = rule?.whenNotRunning {
                let state = probes.processes.state(bundleIDs: g.bundleIDs, names: g.names)
                if state != .notRunning {
                    let reason = state == .running ? Refusal.processRunning : Refusal.processUnknown
                    for item in byRule[ruleID] ?? [] {
                        result.skipped.append((item.path, reason.rawValue))
                    }
                    continue
                }
            }
            var deletables = byRule[ruleID] ?? []
            if rule?.allowance == .aerialVideos {
                // re-read the in-use set right before deleting: a wallpaper change
                // after the scan must not lose its videos, and an unreadable config
                // fails closed the same way the scan did
                let aerial = AerialVideos.scan(home: home)
                if aerial.unavailableReason != nil {
                    for item in deletables { result.skipped.append((item.path, Refusal.inUse.rawValue)) }
                    continue
                }
                deletables = deletables.filter { item in
                    let assetID = (item.path as NSString).deletingPathExtension
                        .components(separatedBy: "/").last ?? ""
                    if aerial.inUseAssetIDs.contains(assetID) {
                        result.skipped.append((item.path, Refusal.inUse.rawValue))
                        return false
                    }
                    return true
                }
            }
            for item in deletables {
                // the scan already sized each item; re-sizing gets only a short deadline
                let outcome: DeleteOutcome
                if rule?.trashOnly == true {
                    outcome = deleter.trash(item.path, expected: item.identity, probes: probes,
                                            allowance: rule?.allowance ?? .none)
                } else {
                    outcome = deleter.remove(item.path, expected: item.identity, dryRun: false,
                                             probes: probes, sizeDeadline: Date().addingTimeInterval(3),
                                             allowance: rule?.allowance ?? .none)
                }
                switch outcome {
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
        }
        return result
    }

    // MARK: candidate expansion

    func candidates(for rule: CleanRule) -> [String] {
        var out: [String] = []
        let minAge = rule.minAgeDays.map { Date().addingTimeInterval(-$0 * 86_400) }
        // unguarded parent rules must not claim a dir a guarded rule targets —
        // ~/Library/Logs/* must leave CoreSimulator to the Simulator-guarded rule
        let guarded = rule.whenNotRunning == nil ? guardedTargets() : []
        for pattern in rule.patterns {
            for path in Self.expand(Whitelist.expand(pattern, home: home)) {
                if guarded.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { continue }
                let name = (path as NSString).lastPathComponent
                if rule.excludeNames.contains(name) { continue }
                if let minAge, let mtime = FileStat.modificationDate(path), mtime > minAge { continue }
                if rule.skipProtectedContainerOwners, isProtectedContainerOwner(path) { continue }
                out.append(path)
            }
        }
        return out
    }

    /// Literal (pre-glob) prefixes of guarded rules' patterns — the dirs they own.
    private func guardedTargets() -> [String] {
        rules.filter { $0.whenNotRunning != nil }.flatMap { rule in
            rule.patterns.map { pattern in
                let expanded = Whitelist.expand(pattern, home: home)
                var prefix = ""
                for component in expanded.split(separator: "/") {
                    if Glob.hasMeta(String(component)) { break }
                    prefix += "/" + component
                }
                return prefix.isEmpty ? expanded : prefix
            }
        }
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
