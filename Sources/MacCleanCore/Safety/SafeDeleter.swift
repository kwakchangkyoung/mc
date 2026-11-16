import Darwin
import Foundation

/// Identity bound at scan time and re-checked right before removal (Mole `_mole_snapshot_path_identity`).
public struct PathIdentity: Sendable, Equatable, Hashable {
    public let parent: FileID?
    public let target: FileID?

    public static func capture(_ path: String) -> PathIdentity {
        PathIdentity(parent: FileStat.lstatID((path as NSString).deletingLastPathComponent),
                     target: FileStat.lstatID(path))
    }
}

public enum DeleteOutcome: Sendable, Equatable {
    case wouldRemove(SizeResult)
    case removed(SizeResult)
    case skipped(Refusal)
    case missing
    case failed(String)
}

/// The single deletion funnel. Every clean removal goes through `remove`.
/// Clean semantics follow Mole: permanent delete (no Trash), dry-run uses the same checks.
public struct SafeDeleter: Sendable {
    public let policy: PathPolicy
    public let whitelist: Whitelist
    public let log: OperationLog?

    public init(policy: PathPolicy, whitelist: Whitelist, log: OperationLog?) {
        self.policy = policy
        self.whitelist = whitelist
        self.log = log
    }

    /// Validation shared by scan (dry-run) and execution.
    /// `forUninstall` matches Mole `MOLE_UNINSTALL_MODE=1`: the user whitelist is not applied
    /// and path protection uses the uninstall rules (system-critical only).
    public func check(_ path: String, probes: ProbeContext, forUninstall: Bool = false) -> Refusal? {
        if let r = policy.validate(path, probes: probes, uninstall: forUninstall) { return r }
        if !forUninstall && whitelist.contains(path) { return .whitelist }
        if ProtectionPolicy.holdsCompiledModelCache(path) { return .compiledModelCache }
        return nil
    }

    public func remove(_ path: String, expected: PathIdentity?, dryRun: Bool, probes: ProbeContext,
                       sizeDeadline: Date = Date().addingTimeInterval(30)) -> DeleteOutcome {
        let command = dryRun ? "clean-dry-run" : "clean"
        if let refusal = check(path, probes: probes) {
            log?.record(command, "SKIPPED", path, refusal.rawValue)
            return .skipped(refusal)
        }
        guard FileStat.exists(path) else { return .missing }

        let size = SizeCalculator.allocatedSize(of: path, deadline: sizeDeadline)
        if dryRun { return .wouldRemove(size) }

        // re-check after sizing: state may have changed meanwhile
        if ProtectionPolicy.holdsCompiledModelCache(path) {
            log?.record(command, "SKIPPED", path, Refusal.compiledModelCache.rawValue)
            return .skipped(.compiledModelCache)
        }
        if let expected, PathIdentity.capture(path) != expected {
            log?.record(command, "SKIPPED", path, Refusal.identityChanged.rawValue)
            return .skipped(.identityChanged)
        }

        let rc = removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
        if rc != 0 {
            let message = String(cString: strerror(errno))
            log?.record(command, "FAILED", path, message)
            return .failed(message)
        }
        log?.record(command, "REMOVED", path, ByteFormat.string(size.bytes, partial: size.partial))
        return .removed(size)
    }

    /// Analyze/uninstall move to Trash (Mole `mo analyze` delete, `mo uninstall` Trash mode).
    /// Same `check` validation as `remove`; if trashing fails there is NO permanent-delete
    /// fallback (DESIGN principle 2).
    public func trash(_ path: String, expected: PathIdentity?, probes: ProbeContext,
                      forUninstall: Bool = false) -> DeleteOutcome {
        let command = forUninstall ? "uninstall" : "trash"
        if let refusal = check(path, probes: probes, forUninstall: forUninstall) {
            log?.record(command, "SKIPPED", path, refusal.rawValue)
            return .skipped(refusal)
        }
        guard FileStat.exists(path) else { return .missing }
        let size = SizeCalculator.allocatedSize(of: path)
        if let expected, PathIdentity.capture(path) != expected {
            log?.record(command, "SKIPPED", path, Refusal.identityChanged.rawValue)
            return .skipped(.identityChanged)
        }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            log?.record(command, "FAILED", path, error.localizedDescription)
            return .failed(error.localizedDescription)
        }
        log?.record(command, "TRASHED", path, ByteFormat.string(size.bytes, partial: size.partial))
        return .removed(size)
    }
}
