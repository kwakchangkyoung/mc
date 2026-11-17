import AppKit
import Darwin
import Foundation

/// Mole three-state process answer. Only `.notRunning` allows a delete.
public enum ProbeState: Sendable, Equatable {
    case running
    case notRunning
    case unknown
}

/// One snapshot of running processes (replaces `pgrep` / `ps -axo`).
public struct ProcessSnapshot: Sendable {
    public struct Entry: Sendable {
        public let pid: pid_t
        public let name: String      // executable basename
        public let path: String      // full executable path ("" if unreadable)
        public let arguments: String // joined argv ("" when not readable, e.g. other users)
        /// One `ps -axo comm,args`-like line used for owner matching.
        public var line: String { name + " " + path + " " + arguments }
    }

    public let entries: [Entry]
    public let bundleIDs: Set<String> // lowercased NSRunningApplication bundle ids
    public let complete: Bool         // false → callers must treat answers as unknown

    public static func capture() -> ProcessSnapshot {
        var bundleIDs = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { bundleIDs.insert(id.lowercased()) }
        }

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ProcessSnapshot(entries: [], bundleIDs: bundleIDs, complete: false) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return ProcessSnapshot(entries: [], bundleIDs: bundleIDs, complete: false) }

        var entries: [Entry] = []
        var complete = true
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var path = ""
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                path = String(cString: pathBuf)
            }
            var name = (path as NSString).lastPathComponent
            if name.isEmpty {
                var nameBuf = [CChar](repeating: 0, count: 256)
                if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 { name = String(cString: nameBuf) }
            }
            // a live same-user process whose executable cannot be resolved at all is a
            // probe failure (other users' pids return EPERM from kill and are tolerated;
            // zombies have no executable by definition, so they must not count)
            if name.isEmpty && path.isEmpty && kill(pid, 0) == 0 && !Self.isZombie(pid) {
                complete = false
            }
            entries.append(Entry(pid: pid, name: name, path: path, arguments: Self.arguments(of: pid)))
        }
        return ProcessSnapshot(entries: entries, bundleIDs: bundleIDs, complete: complete)
    }

    /// SZOMB via KERN_PROC_PID — zombies fail proc_pidpath/proc_name legitimately
    /// (proc_pidinfo returns nothing for them, so bsdinfo cannot be used here).
    private static func isZombie(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        return sysctl(&mib, 4, &kp, &size, nil, 0) == 0 && kp.kp_proc.p_stat == SZOMB
    }

    /// argv via KERN_PROCARGS2 (layout: argc, exec path, NUL padding, argv strings...).
    static func arguments(of pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return "" }
        var index = MemoryLayout<Int32>.size
        while index < size && buf[index] != 0 { index += 1 }      // exec path
        while index < size && buf[index] == 0 { index += 1 }      // padding
        var args: [String] = []
        while index < size && args.count < Int(argc) {
            let start = index
            while index < size && buf[index] != 0 { index += 1 }
            args.append(String(decoding: buf[start..<index], as: UTF8.self))
            index += 1
        }
        return args.joined(separator: " ")
    }

    /// Port of Mole `_mole_user_cache_owner_process_state` (file_ops.sh): does a running process
    /// belong to the reverse-DNS cache owner? Mole's extra "line belongs to another app" filter is
    /// not ported, so this answers `.running` at least as often as Mole (more conservative).
    public func cacheOwnerState(_ owner: String) -> ProbeState {
        guard complete else { return .unknown }
        let lowerOwner = owner.lowercased()
        if bundleIDs.contains(lowerOwner) { return .running }
        let lines = entries.map { $0.line.lowercased() }
        if lines.contains(where: { $0.contains(lowerOwner) }) { return .running }

        let parts = lowerOwner.split(separator: ".").map(String.init)
        guard parts.count > 1, let leaf = parts.last, leaf.count >= 4 else { return .notRunning }
        let corroborators = parts.dropLast().filter { $0.count >= 4 && $0 != "com" }
        guard !corroborators.isEmpty else { return .notRunning }
        for line in lines where Self.containsWord(leaf, in: line) {
            if corroborators.contains(where: { Self.containsWord($0, in: line) }) { return .running }
        }
        return .notRunning
    }

    static func containsWord(_ word: String, in line: String) -> Bool {
        var searchRange = line.startIndex..<line.endIndex
        while let r = line.range(of: word, range: searchRange) {
            let beforeOK = r.lowerBound == line.startIndex
                || !(line[line.index(before: r.lowerBound)].isLetter || line[line.index(before: r.lowerBound)].isNumber)
            let afterOK = r.upperBound == line.endIndex
                || !(line[r.upperBound].isLetter || line[r.upperBound].isNumber)
            if beforeOK && afterOK { return true }
            searchRange = r.upperBound..<line.endIndex
        }
        return false
    }

    /// `pgrep -x name` equivalent (case-sensitive exact executable name).
    public func state(names: [String]) -> ProbeState {
        guard complete else { return .unknown }
        let set = Set(names)
        return entries.contains { set.contains($0.name) } ? .running : .notRunning
    }

    /// Running state of an app by bundle id (NSWorkspace) or by an executable inside `<anything>/<App>.app/`.
    public func state(bundleID: String) -> ProbeState {
        guard complete else { return .unknown }
        return bundleIDs.contains(bundleID.lowercased()) ? .running : .notRunning
    }

    /// Combined probe: any listed bundle id or executable name running.
    public func state(bundleIDs ids: [String], names: [String]) -> ProbeState {
        guard complete else { return .unknown }
        if ids.contains(where: { bundleIDs.contains($0.lowercased()) }) { return .running }
        return state(names: names)
    }

    public func isAlive(pid: pid_t) -> ProbeState {
        if kill(pid, 0) == 0 { return .running }
        return errno == ESRCH ? .notRunning : .unknown
    }
}
