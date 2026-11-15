import Darwin
import Foundation

public struct SizeResult: Sendable, Equatable {
    public var bytes: Int64
    /// true when the walk hit the deadline or an unreadable subtree (shown as "X+").
    public var partial: Bool

    public static let zero = SizeResult(bytes: 0, partial: false)
}

/// Allocated (physical) size like Mole `du -skP`: no symlink following, same device only,
/// hard links counted once within one measurement.
public enum SizeCalculator {
    public static func allocatedSize(of path: String, deadline: Date = .distantFuture) -> SizeResult {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .zero }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            return SizeResult(bytes: Int64(st.st_blocks) * 512, partial: false)
        }

        var total: Int64 = 0
        var partial = false
        var seenLinks = Set<FileID>()
        var counter = 0

        let cPath = strdup(path)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            return SizeResult(bytes: 0, partial: true)
        }
        defer { fts_close(fts) }

        while let ent = fts_read(fts) {
            counter += 1
            if counter % 512 == 0 && Date() > deadline {
                partial = true
                break
            }
            let info = Int32(ent.pointee.fts_info)
            switch info {
            case FTS_DP:
                continue
            case FTS_DNR, FTS_ERR, FTS_NS:
                partial = true
                continue
            default:
                break
            }
            guard let sp = ent.pointee.fts_statp else { continue }
            let s = sp.pointee
            if (s.st_mode & S_IFMT) != S_IFDIR && s.st_nlink > 1 {
                let id = FileID(dev: UInt64(UInt32(bitPattern: s.st_dev)), ino: UInt64(s.st_ino))
                if !seenLinks.insert(id).inserted { continue }
            }
            total += Int64(s.st_blocks) * 512
        }
        return SizeResult(bytes: total, partial: partial)
    }
}

public enum ByteFormat {
    /// Mole uses 1000-based units in its summaries (e.g. "3.27GB").
    public static func string(_ bytes: Int64, partial: Bool = false) -> String {
        let s = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return partial ? s + "+" : s
    }
}
