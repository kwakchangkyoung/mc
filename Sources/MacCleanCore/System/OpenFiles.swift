import Darwin
import Foundation

/// Snapshot of every vnode path opened by this user's processes (replaces Mole's `lsof` probes).
/// Processes owned by other users are not inspectable without root; they cannot hold this
/// user's cache files open in the normal case, so they are skipped. A failure on one of our
/// own processes makes the snapshot incomplete → callers answer `.unknown`.
public struct OpenFilesSnapshot: Sendable {
    public let paths: [String]
    public let complete: Bool

    public static func capture() -> OpenFilesSnapshot {
        let uid = getuid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return OpenFilesSnapshot(paths: [], complete: false) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return OpenFilesSnapshot(paths: [], complete: false) }

        var result: [String] = []
        var complete = true
        let selfPid = getpid()
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != selfPid {
            var bsd = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            errno = 0
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, infoSize) == infoSize else {
                if !Self.isBenignProbeError(errno) { complete = false }
                continue
            }
            guard bsd.pbi_uid == uid else { continue }

            errno = 0
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdBytes > 0 else {
                // proc_pidinfo reports failure as 0 (not <0); a zero result on one of our
                // own processes is a probe failure, not "no fds"
                if !Self.isBenignProbeError(errno) { complete = false }
                continue
            }
            let fdCount = Int(fdBytes) / MemoryLayout<proc_fdinfo>.size
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount + 16)
            errno = 0
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard got > 0 else {
                if !Self.isBenignProbeError(errno) { complete = false }
                continue
            }
            let n = Int(got) / MemoryLayout<proc_fdinfo>.size
            for fd in fds.prefix(n) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vinfo = vnode_fdinfowithpath()
                let vsize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vinfo, vsize) == vsize else { continue }
                let path = withUnsafeBytes(of: &vinfo.pvip.vip_path) { raw -> String in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                if !path.isEmpty { result.append(path) }
            }
        }
        return OpenFilesSnapshot(paths: result, complete: complete)
    }

    /// Probe failures that do not make the snapshot incomplete: the process is gone
    /// (ESRCH) or belongs to another user and cannot be inspected (EPERM).
    static func isBenignProbeError(_ code: Int32) -> Bool {
        code == ESRCH || code == EPERM
    }

    /// Is any file at `path` (or below it, for a directory) open?
    public func state(under path: String) -> ProbeState {
        guard complete else { return .unknown }
        let candidates = [path, FileStat.realPath(path)].compactMap { $0 }
        for open in paths {
            for root in candidates where open == root || open.hasPrefix(root + "/") {
                return .running
            }
        }
        return .notRunning
    }
}
