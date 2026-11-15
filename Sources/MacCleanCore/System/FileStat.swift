import Darwin
import Foundation

/// dev:inode identity of a filesystem object (Mole `stat -f %d:%i`).
public struct FileID: Hashable, Sendable {
    public let dev: UInt64
    public let ino: UInt64
}

/// `stat(2)` (follows symlinks); file-scope wrapper because `stat` also names the struct.
func followStat(_ path: String, _ buf: UnsafeMutablePointer<stat>) -> Int32 {
    stat(path, buf)
}

public enum FileStat {
    /// lstat: does not follow a leaf symlink.
    public static func lstatID(_ path: String) -> FileID? {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return FileID(dev: UInt64(UInt32(bitPattern: st.st_dev)), ino: UInt64(st.st_ino))
    }

    /// stat: follows symlinks (used for "same existing file" checks, bash `-ef`).
    public static func statID(_ path: String) -> FileID? {
        var st = stat()
        guard followStat(path, &st) == 0 else { return nil }
        return FileID(dev: UInt64(UInt32(bitPattern: st.st_dev)), ino: UInt64(st.st_ino))
    }

    public static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return Darwin.lstat(path, &st) == 0
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        let ts = st.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }

    public static func readLink(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = Darwin.readlink(path, &buf, buf.count - 1)
        guard n >= 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    /// Physical path with every symlink resolved (bash `cd -P`). nil if it does not exist.
    public static func realPath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
