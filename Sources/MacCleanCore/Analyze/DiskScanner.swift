import Darwin
import Foundation

/// A direct child of the scanned directory: one row in the analyzer list.
public struct AnalyzeEntry: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    /// Recursive allocated size (Mole `getActualFileSize`: min(st_blocks*512, st_size)).
    public let size: Int64
    /// true for directories and symlinks whose target is a directory (drillable, like Mole).
    public let isDir: Bool
    public let isSymlink: Bool
    /// Regular files inside this subtree (Mole TotalFiles semantics); 1 for a file entry itself.
    public let itemCount: Int
    /// true when part of the subtree could not be read.
    public let partial: Bool
    /// dev:inode bound at scan time; re-checked by SafeDeleter before any move to Trash.
    public let identity: PathIdentity
}

/// A large-file candidate collected during the walk (Mole `fileEntry`).
public struct LargeFile: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    /// dev:inode bound at scan time; re-checked by SafeDeleter before any move to Trash.
    public let identity: PathIdentity
    public var name: String { (path as NSString).lastPathComponent }
}

public struct AnalyzeResult: Sendable {
    public let root: String
    /// Direct children, size descending (path ascending on ties, Mole `sizePathBefore`).
    public var entries: [AnalyzeEntry]
    /// Top-N files over `largeFileMinBytes`, size descending.
    public var largeFiles: [LargeFile]
    public var totalSize: Int64
    public var totalFiles: Int
    /// true when some subtree could not be fully read.
    public var partial: Bool
    /// true when the scan was cancelled before completion.
    public var cancelled: Bool
}

public enum AnalyzeError: Error, Equatable {
    case notFound(String)
    case notDirectory(String)
    case notReadable(String)
}

/// Cooperative cancellation shared between the UI and background scan workers.
public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { flag } }
    public func cancel() { lock.withLock { flag = true } }
}

/// Hard-link identity set shared by the whole scan pass (Mole `scanLimiter.seen`).
private final class SeenLinks: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<FileID>()
    func insert(_ id: FileID) -> Bool { lock.withLock { set.insert(id).inserted } }
}

/// Directory analyzer (Mole `mo analyze`, scanner.go). For a directory it returns its direct
/// children with their recursive allocated size, plus a top-N large-file list. Symlinks are
/// never followed, hard links count once per scan, only the root's volume is walked, and
/// children are measured in parallel. No on-disk cache.
public struct DiskScanner: Sendable {
    /// Large-file list keeps at most this many entries (Mole Top-20 heap).
    public var maxLargeFiles = 20
    /// Files at or above this size become large-file candidates (Mole Spotlight threshold 100MB
    /// is skipped; the heap effectively collects every file, so we bound it with a threshold).
    public var largeFileMinBytes: Int64 = 1_000_000

    public init() {}

    /// Child dirs never descended into (Mole `defaultSkipDirs`).
    static let skipDirs: Set<String> = ["nfs", "PHD", "Permissions", "OrbStack", "Colima",
                                        "VMware Fusion", "VirtualBox VMs", "Rancher Desktop",
                                        ".lima", ".colima", ".orbstack"]

    /// Children skipped when the scanned root is "/" (Mole `skipSystemDirs`; opt/usr are scanned).
    static let skipSystemDirs: Set<String> = ["dev", "tmp", "private", "cores", "net", "home",
        "System", "sbin", "bin", "etc", "var", "Volumes", "Network", ".vol", ".Spotlight-V100",
        ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", ".MobileBackups"]

    /// Dirs measured but not searched for large-file candidates (Mole `foldDirs`).
    static let foldedDirs: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".npm", "_npx", "_cacache", "_logs", "_locks", "_quick", "_libvips",
        "_prebuilds", "_update-notifier-last-checked", ".yarn", ".pnpm-store", ".next", ".nuxt",
        "bower_components", ".vite", ".turbo", ".parcel-cache", ".nx", ".rush", "tnpm", ".tnpm",
        ".bun", ".deno",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "venv", ".venv", "virtualenv",
        ".tox", "site-packages", ".eggs", ".pyenv", ".poetry", ".pip", ".pipx",
        "vendor", ".bundle", "gems", ".rbenv", "target", ".gradle", ".m2", ".ivy2", "out", "pkg",
        "composer.phar", ".composer", ".cargo",
        "build", "dist", ".output", "coverage", ".coverage",
        ".idea", ".vscode", ".vs", ".fleet",
        ".cache", "__MACOSX", ".DS_Store", ".Trash", "Caches", ".Spotlight-V100", ".fseventsd",
        ".DocumentRevisions-V100", ".TemporaryItems", "$RECYCLE.BIN", ".temp", ".tmp", "_temp",
        "_tmp", ".Homebrew", ".rustup", ".sdkman", ".nvm",
        "Application Scripts", "Saved Application State", "Mobile Documents",
        ".docker", ".containerd", "Pods", "DerivedData", ".build", "xcuserdata", "Carthage",
        ".dart_tool", ".angular", ".svelte-kit", ".astro", ".solid", ".mysql", ".postgres",
        "mongodb", ".terraform", ".vagrant", "tmp", "temp",
    ]

    /// Extensions excluded from the large-file list (Mole `skipExtensions`).
    static let skipExtensions: Set<String> = [
        "go", "js", "ts", "tsx", "jsx", "json", "md", "txt", "yml", "yaml", "xml", "html", "css",
        "scss", "sass", "less", "py", "rb", "java", "kt", "rs", "swift", "m", "mm", "c", "cpp",
        "h", "hpp", "cs", "sql", "db", "lock", "gradle", "mjs", "cjs", "coffee", "dart", "svelte",
        "vue", "nim", "hx",
    ]

    public func scan(_ rawPath: String, cancellation: ScanCancellation? = nil) throws -> AnalyzeResult {
        let root = PathPolicy.normalize(rawPath)
        var st = stat()
        // the root itself may be a symlink to a directory
        guard followStat(root, &st) == 0 else { throw AnalyzeError.notFound(root) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw AnalyzeError.notDirectory(root) }
        let rootDev = st.st_dev
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            throw AnalyzeError.notReadable(root)
        }

        let children = names.filter { name in
            if Self.skipDirs.contains(name) { return false }
            if root == "/" && Self.skipSystemDirs.contains(name) { return false }
            return true
        }

        let seen = SeenLinks()
        var boxes = [Measured](repeating: Measured(), count: children.count)
        boxes.withUnsafeMutableBufferPointer { buf in
            let b = buf
            DispatchQueue.concurrentPerform(iterations: children.count) { i in
                if cancellation?.isCancelled == true { return }
                b[i] = self.measure(root + "/" + children[i], name: children[i],
                                    rootDev: rootDev, seen: seen, cancellation: cancellation)
            }
        }

        var result = AnalyzeResult(root: root, entries: [], largeFiles: [],
                                   totalSize: 0, totalFiles: 0,
                                   partial: false, cancelled: cancellation?.isCancelled == true)
        for box in boxes {
            guard let entry = box.entry else { continue }
            result.entries.append(entry)
            result.totalSize += entry.size
            result.totalFiles += entry.itemCount
            result.partial = result.partial || entry.partial
            merge(&result.largeFiles, box.top)
        }
        sortTop(&result.largeFiles)
        result.entries.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        return result
    }

    // MARK: subtree measurement

    private func measure(_ path: String, name: String, rootDev: dev_t, seen: SeenLinks,
                         cancellation: ScanCancellation?) -> Measured {
        let identity = PathIdentity.capture(path)
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return Measured(entry: AnalyzeEntry(name: name, path: path, size: 0, isDir: false,
                                                isSymlink: false, itemCount: 0, partial: true,
                                                identity: identity))
        }
        let mode = st.st_mode & S_IFMT

        if mode == S_IFLNK {
            // the link itself only; a dir target is marked drillable but never descended
            var t = stat()
            let dirTarget = followStat(path, &t) == 0 && (t.st_mode & S_IFMT) == S_IFDIR
            return Measured(entry: AnalyzeEntry(name: name, path: path, size: actualSize(st),
                                                isDir: dirTarget, isSymlink: true,
                                                itemCount: 0, partial: false,
                                                identity: identity))
        }

        if mode != S_IFDIR {
            var top: [LargeFile] = []
            let size = mode == S_IFREG
                ? countable(st, path: path, seen: seen, collect: true, top: &top)
                : actualSize(st)
            return Measured(entry: AnalyzeEntry(name: name, path: path, size: size, isDir: false,
                                                isSymlink: false,
                                                itemCount: mode == S_IFREG ? 1 : 0,
                                                partial: false, identity: identity),
                            top: top)
        }

        var total = actualSize(st)
        var count = 0                     // regular files only, like Mole TotalFiles
        var partial = false
        var top: [LargeFile] = []
        // a mounted volume or firmlink reports a different device: list it but do not descend
        if st.st_dev != rootDev {
            return Measured(entry: AnalyzeEntry(name: name, path: path, size: total, isDir: true,
                                                isSymlink: false, itemCount: count, partial: false,
                                                identity: identity))
        }

        var visited = 0
        var stack: [(dir: String, collect: Bool)] = [(path, !Self.foldedDirs.contains(name))]
        while let (dir, collect) = stack.popLast() {
            if cancellation?.isCancelled == true { partial = true; break }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                partial = true
                continue
            }
            for child in names {
                visited += 1
                if visited % 256 == 0 && cancellation?.isCancelled == true { partial = true; break }
                let childPath = dir + "/" + child
                var cs = stat()
                guard lstat(childPath, &cs) == 0 else { partial = true; continue }
                let cm = cs.st_mode & S_IFMT
                if cm == S_IFDIR {
                    total += actualSize(cs)
                    if cs.st_dev == rootDev {
                        stack.append((childPath, collect && !Self.foldedDirs.contains(child)))
                    }
                } else if cm == S_IFLNK {
                    total += actualSize(cs)
                } else if cm == S_IFREG {
                    if collect { count += 1 }   // folded-dir contents are not enumerated (Mole)
                    total += countable(cs, path: childPath, seen: seen, collect: collect, top: &top)
                } else {
                    total += actualSize(cs)
                }
            }
        }
        sortTop(&top)
        return Measured(entry: AnalyzeEntry(name: name, path: path, size: total, isDir: true,
                                            isSymlink: false, itemCount: count, partial: partial,
                                            identity: identity),
                        top: top)
    }

    private struct Measured: Sendable {
        var entry: AnalyzeEntry?
        var top: [LargeFile] = []
    }

    /// Mole `countableFileSize`: hard links (nlink>1) count once per scan pass.
    /// A regular file over the threshold also becomes a large-file candidate.
    private func countable(_ st: stat, path: String, seen: SeenLinks,
                           collect: Bool, top: inout [LargeFile]) -> Int64 {
        if st.st_nlink > 1 {
            let id = FileID(dev: UInt64(UInt32(bitPattern: st.st_dev)), ino: UInt64(st.st_ino))
            if !seen.insert(id) { return 0 }
        }
        let size = actualSize(st)
        if collect, size >= largeFileMinBytes,
           !Self.skipExtensions.contains((path as NSString).pathExtension.lowercased()) {
            push(&top, LargeFile(path: path, size: size, identity: PathIdentity.capture(path)))
        }
        return size
    }

    /// Mole `getActualFileSize`: min(allocated blocks, logical size).
    private func actualSize(_ st: stat) -> Int64 {
        min(Int64(st.st_blocks) * 512, st.st_size)
    }

    private func push(_ top: inout [LargeFile], _ file: LargeFile) {
        top.append(file)
        if top.count > maxLargeFiles * 4 { sortTop(&top) }
    }

    private func merge(_ into: inout [LargeFile], _ files: [LargeFile]) {
        into.append(contentsOf: files)
        if into.count > maxLargeFiles * 4 { sortTop(&into) }
    }

    private func sortTop(_ files: inout [LargeFile]) {
        files.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        if files.count > maxLargeFiles { files.removeSubrange(maxLargeFiles...) }
    }
}
