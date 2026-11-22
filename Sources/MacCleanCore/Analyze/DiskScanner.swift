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
    /// Aggregated per-directory data for instant drill-in; only set by `keepTree` scans.
    public var tree: AnalyzeNode?
}

/// A non-directory child kept from a `keepTree` scan (files, symlinks, sockets…).
public struct ChildFile: Sendable {
    public let name: String
    public let size: Int64
    public let itemCount: Int
    public let isSymlink: Bool
    /// true when the entry's attributes could not be fully read.
    public let partial: Bool
    /// Scan-time dev:inode of the child and of its parent directory.
    public let fileID: FileID
    public let parentID: FileID
    public var identity: PathIdentity { PathIdentity(parent: parentID, target: fileID) }
}

/// One directory's aggregated children kept from a `keepTree` scan, for drill-in
/// without a rescan. Only directories become nodes; files stay as ChildFile records.
public final class AnalyzeNode: @unchecked Sendable {
    public let path: String
    public let name: String
    /// This entry's size in the parent's listing (own dir entry + subtree).
    public let size: Int64
    /// Sum of direct children — the drilled view's TOTAL.
    public let childrenTotal: Int64
    public let itemCount: Int
    public let partial: Bool
    /// dev:inode bound at scan time; re-checked by SafeDeleter before any move to Trash.
    public let identity: PathIdentity
    /// Different volume / firmlink: children were never walked, so drill-in rescans.
    public let isOtherDevice: Bool
    /// false under folded dirs: file counts and large files were not collected there,
    /// so drill-in rescans for full detail like the pre-cached behavior did.
    public let collected: Bool
    /// Subdirectory nodes (drillable).
    public let dirs: [AnalyzeNode]
    public let files: [ChildFile]
    /// Top large-file candidates inside this subtree (same selection as a rescan).
    public let topFiles: [LargeFile]

    public init(path: String, name: String, size: Int64, childrenTotal: Int64, itemCount: Int,
                partial: Bool, identity: PathIdentity, isOtherDevice: Bool, collected: Bool,
                dirs: [AnalyzeNode], files: [ChildFile], topFiles: [LargeFile]) {
        self.path = path; self.name = name; self.size = size
        self.childrenTotal = childrenTotal; self.itemCount = itemCount
        self.partial = partial; self.identity = identity; self.isOtherDevice = isOtherDevice
        self.collected = collected
        self.dirs = dirs; self.files = files; self.topFiles = topFiles
    }

    /// The node's own display row in a parent listing.
    public var entry: AnalyzeEntry {
        AnalyzeEntry(name: name, path: path, size: size, isDir: true, isSymlink: false,
                     itemCount: itemCount, partial: partial, identity: identity)
    }

    /// Direct children as display rows, sorted like `AnalyzeResult.entries`.
    public func childEntries() -> [AnalyzeEntry] {
        var rows = dirs.map(\.entry)
        rows += files.map {
            // a symlink whose target is a directory is drillable, matching a fresh scan
            let p = DiskScanner.join(path, $0.name)
            return AnalyzeEntry(name: $0.name, path: p, size: $0.size,
                                isDir: $0.isSymlink && DiskScanner.isDirTarget(p),
                                isSymlink: $0.isSymlink, itemCount: $0.itemCount,
                                partial: $0.partial, identity: $0.identity)
        }
        rows.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        return rows
    }

    /// Result-shaped snapshot for this node (drilled view).
    public func asResult() -> AnalyzeResult {
        AnalyzeResult(root: path, entries: childEntries(), largeFiles: topFiles,
                      totalSize: childrenTotal, totalFiles: itemCount,
                      partial: partial, cancelled: false, tree: self)
    }
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

/// One directory entry returned by getattrlistbulk.
private struct BulkEntry {
    var name = ""
    var dev: UInt32 = 0
    var ino: UInt64 = 0
    /// vnode type: VREG=1, VDIR=2, VLNK=5; other values count as "other".
    var objtype: UInt32 = 0
    var nlink: UInt32 = 1
    var dataLength: Int64 = 0
    var allocSize: Int64 = 0
    /// DIR_MNTSTATUS_MNTPOINT — getattrlistbulk reports the covering volume's DEVID for
    /// mount-point dirs, so they need their own flag to stay unwalked
    var mountPoint = false
    var error = false
}

/// One directory's walk accumulators. Written only by the worker owning the read and
/// published under the shared lock, so no lock is needed inside the entry loop.
private struct Accum {
    var agg: Int64 = 0
    var count = 0
    var partial = false
    var files: [ChildFile] = []
    var candidates: [LargeFile] = []
    var seen = 0
    var cancelled = false
}

/// A directory queued for (or in the middle of) a parallel walk.
private final class DirWork {
    let path: String
    let name: String
    /// This dir's own dev:inode — also the parent FileID of its children.
    let dirID: FileID
    /// actualSize of the dir entry itself, taken from the parent's bulk read.
    let ownEntry: Int64
    /// Large-file collection on (false under folded dirs).
    let collect: Bool
    /// The scan root itself (its children become AnalyzeResult.entries).
    let isRoot: Bool
    /// true when this dir lives on another volume/firmlink and must not be walked.
    let otherDevice: Bool
    /// Alive while any child is unfinished (children only finalize before the parent).
    unowned let parent: DirWork?
    var read = false
    var finalized = false
    var pendingChildren = 0
    var agg: Int64 = 0          // children bytes: non-dir sizes + finalized subdir totals
    var count = 0
    var partial = false
    /// Discovered subdirectories; strong refs keep the live tree alive until finalize.
    var subdirs: [DirWork] = []
    var files: [ChildFile] = []
    var largeCandidates: [LargeFile] = []
    var node: AnalyzeNode?

    init(path: String, name: String, dirID: FileID, ownEntry: Int64, collect: Bool,
         isRoot: Bool, otherDevice: Bool, parent: DirWork?) {
        self.path = path; self.name = name; self.dirID = dirID
        self.ownEntry = ownEntry; self.collect = collect
        self.isRoot = isRoot; self.otherDevice = otherDevice; self.parent = parent
    }
}

/// Mutable state shared by the worker pool.
private final class ScanState: @unchecked Sendable {
    let lock = NSCondition()
    var stack: [DirWork] = []
    /// Directories discovered but not yet finalized; 0 ⇒ all workers may exit.
    var liveDirs = 0
    /// Root's completed child dirs; their totals become the entry list.
    var rootDirs: [DirWork] = []
}

/// Directory analyzer (Mole `mo analyze`, scanner.go). For a directory it returns its
/// direct children with recursive allocated size plus a top-N large-file list. Symlinks
/// are never followed, hard links count once per scan, only the root's volume is walked.
/// Directories are read with getattrlistbulk and walked by a bounded worker pool over a
/// shared queue, so one huge child no longer serializes the whole subtree. With
/// `keepTree` the aggregated per-directory children are kept for instant drill-in.
public struct DiskScanner: Sendable {
    /// Large-file list keeps at most this many entries (Mole Top-20 heap).
    public var maxLargeFiles = 20
    /// Files at or above this size become large-file candidates.
    public var largeFileMinBytes: Int64 = 1_000_000
    /// Directory-walk workers; tests lower it to compare against a serial pass.
    var workerCount = ProcessInfo.processInfo.activeProcessorCount

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

    public func scan(_ rawPath: String, cancellation: ScanCancellation? = nil,
                     keepTree: Bool = false) throws -> AnalyzeResult {
        let root = PathPolicy.normalize(rawPath)
        var st = stat()
        // the root itself may be a symlink to a directory
        guard followStat(root, &st) == 0 else { throw AnalyzeError.notFound(root) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw AnalyzeError.notDirectory(root) }
        let rootDev = UInt64(UInt32(bitPattern: st.st_dev))
        let rootID = FileID(dev: rootDev, ino: UInt64(st.st_ino))

        let state = ScanState()
        let seen = SeenLinks()
        let rootWork = DirWork(path: root, name: (root as NSString).lastPathComponent,
                               dirID: rootID, ownEntry: 0, collect: true,
                               isRoot: true, otherDevice: false, parent: nil)
        var buffer = [CChar](repeating: 0, count: 256 * 1024)
        state.liveDirs = 1
        // root listing runs synchronously so an unreadable root still throws
        let opened = buffer.withUnsafeMutableBufferPointer { buf in
            readDir(rootWork, state: state, rootDev: rootDev, seen: seen,
                    keepTree: keepTree, cancellation: cancellation,
                    isRoot: true, buffer: buf)
        }
        if !opened { throw AnalyzeError.notReadable(root) }

        let workers = min(max(1, workerCount), 64)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            // each worker owns its bulk-read buffer for the whole loop
            var own = [CChar](repeating: 0, count: 256 * 1024)
            own.withUnsafeMutableBufferPointer { buf in
                workerLoop(state: state, rootDev: rootDev, seen: seen,
                           keepTree: keepTree, cancellation: cancellation, buffer: buf)
            }
        }

        // root's children become the entry list (dirs arrived via finish() → rootDirs)
        var result = AnalyzeResult(root: root, entries: [], largeFiles: [],
                                   totalSize: rootWork.agg, totalFiles: rootWork.count,
                                   partial: rootWork.partial,
                                   cancelled: cancellation?.isCancelled == true)
        for f in rootWork.files {
            let p = Self.join(root, f.name)
            result.entries.append(AnalyzeEntry(
                name: f.name, path: p, size: f.size,
                isDir: f.isSymlink && Self.isDirTarget(p), isSymlink: f.isSymlink,
                itemCount: f.itemCount, partial: f.partial, identity: f.identity))
        }
        for d in state.rootDirs {
            result.entries.append(AnalyzeEntry(
                name: d.name, path: d.path, size: d.ownEntry + d.agg, isDir: true,
                isSymlink: false, itemCount: d.count, partial: d.partial,
                identity: PathIdentity(parent: rootID, target: d.dirID)))
        }
        sortTop(&rootWork.largeCandidates)
        result.largeFiles = rootWork.largeCandidates
        result.entries.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        result.tree = rootWork.node
        return result
    }

    // MARK: worker pool

    private func workerLoop(state: ScanState, rootDev: UInt64, seen: SeenLinks,
                            keepTree: Bool, cancellation: ScanCancellation?,
                            buffer: UnsafeMutableBufferPointer<CChar>) {
        while true {
            state.lock.lock()
            while state.stack.isEmpty && state.liveDirs > 0 {
                if cancellation?.isCancelled == true {
                    state.lock.unlock()
                    state.lock.broadcast()
                    return
                }
                state.lock.wait(until: Date().addingTimeInterval(0.1))
            }
            if state.liveDirs == 0 {
                state.lock.unlock()
                state.lock.broadcast()
                return
            }
            let work = state.stack.removeLast()
            state.lock.unlock()

            if cancellation?.isCancelled == true {
                state.lock.lock()
                work.read = true
                work.partial = true
                finish(work, state: state, keepTree: keepTree)
                state.lock.unlock()
                continue
            }
            _ = readDir(work, state: state, rootDev: rootDev, seen: seen,
                        keepTree: keepTree, cancellation: cancellation,
                        isRoot: false, buffer: buffer)
        }
    }

    /// Read one directory's entries via getattrlistbulk and queue subdirectories.
    /// Runs outside the shared lock; everything is published under it at the end.
    /// Returns whether the directory could be opened (used for the notReadable root check).
    private func readDir(_ work: DirWork, state: ScanState, rootDev: UInt64,
                         seen: SeenLinks, keepTree: Bool,
                         cancellation: ScanCancellation?, isRoot: Bool,
                         buffer: UnsafeMutableBufferPointer<CChar>) -> Bool {
        let keepChildren = keepTree || isRoot
        var accum = Accum()
        var discovered: [DirWork] = []
        var opened = false
        defer {
            state.lock.lock()
            work.read = true
            work.partial = work.partial || accum.partial
            work.agg += accum.agg
            work.count += accum.count
            work.files = accum.files
            merge(&work.largeCandidates, accum.candidates)
            // children are owned by their parent's list from discovery on — that is
            // what keeps an un-read-but-queued child's unowned parent alive
            work.subdirs.append(contentsOf: discovered)
            work.pendingChildren += discovered.count
            state.liveDirs += discovered.count
            state.stack.append(contentsOf: discovered)
            if !discovered.isEmpty { state.lock.broadcast() }
            finish(work, state: state, keepTree: keepTree)
            state.lock.unlock()
        }
        // other volumes/firmlinks are listed but never walked
        if work.otherDevice { return true }
        if cancellation?.isCancelled == true { accum.partial = true; return true }

        let fd = open(work.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            accum.partial = true
            return false
        }
        opened = true
        defer { close(fd) }

        // DEVID lies for mount points (it reports the covering volume): verify the
        // opened dir is really on the root volume before walking it
        var fst = stat()
        if fstat(fd, &fst) == 0, UInt64(UInt32(bitPattern: fst.st_dev)) != rootDev {
            return true
        }

        while true {
            var attrs = Self.bulkAttrs
            let n = getattrlistbulk(fd, &attrs,
                                    buffer.baseAddress, buffer.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                accum.partial = true
                break
            }
            if n == 0 { break }
            let raw = UnsafeBufferPointer(buffer)
            var off = 0
            for _ in 0..<n {
                let entry = Self.parseEntry(raw, at: &off)
                accum.seen += 1
                if accum.seen % 256 == 0, cancellation?.isCancelled == true {
                    accum.partial = true
                    accum.cancelled = true
                    break
                }
                if entry.error {
                    accum.partial = true
                    // keep a zero-size partial row like the old per-entry lstat path did
                    if keepChildren, !entry.name.isEmpty {
                        accum.files.append(ChildFile(
                            name: entry.name, size: 0, itemCount: 0, isSymlink: false,
                            partial: true,
                            fileID: FileID(dev: UInt64(entry.dev), ino: entry.ino),
                            parentID: work.dirID))
                    }
                    continue
                }
                if isRoot && (Self.skipDirs.contains(entry.name)
                              || (work.path == "/" && Self.skipSystemDirs.contains(entry.name))) {
                    continue
                }
                handle(entry, of: work, rootDev: rootDev, seen: seen,
                       keepChildren: keepChildren,
                       discovered: &discovered, accum: &accum)
            }
            if accum.cancelled || cancellation?.isCancelled == true {
                accum.partial = true
                break
            }
        }
        return opened
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// Accumulate one bulk entry into the dir's totals; queue same-device subdirs.
    private func handle(_ entry: BulkEntry, of work: DirWork, rootDev: UInt64,
                        seen: SeenLinks, keepChildren: Bool,
                        discovered: inout [DirWork], accum: inout Accum) {
        let size = min(entry.allocSize, entry.dataLength)     // Mole getActualFileSize
        let fileID = FileID(dev: UInt64(entry.dev), ino: entry.ino)
        let childPath = Self.join(work.path, entry.name)
        switch entry.objtype {
        case 2:                                                 // VDIR
            // DEVID reports the covering volume on a mount point — treat as other-device
            let other = UInt64(entry.dev) != rootDev || entry.mountPoint
            if !other || keepChildren {
                // the dir's own entry size rides the queue and lands via finish()
                discovered.append(DirWork(
                    path: childPath, name: entry.name, dirID: fileID, ownEntry: size,
                    collect: work.collect && !Self.foldedDirs.contains(entry.name),
                    isRoot: false, otherDevice: other, parent: work))
            } else {
                accum.agg += size      // other volume/firmlink: own entry only, never walked
            }
        case 5:                                                 // VLNK — never followed
            accum.agg += size
            if keepChildren {
                accum.files.append(ChildFile(name: entry.name, size: size, itemCount: 0,
                                             isSymlink: true, partial: false,
                                             fileID: fileID, parentID: work.dirID))
            }
        case 1:                                                 // VREG
            if work.collect { accum.count += 1 }
            var size = size
            if entry.nlink > 1, !seen.insert(fileID) { size = 0 }
            accum.agg += size
            if work.collect, size >= largeFileMinBytes,
               !Self.skipExtensions.contains((childPath as NSString).pathExtension.lowercased()) {
                push(&accum.candidates,
                     LargeFile(path: childPath, size: size,
                               identity: PathIdentity(parent: work.dirID, target: fileID)))
            }
            if keepChildren {
                accum.files.append(ChildFile(name: entry.name, size: size, itemCount: 1,
                                             isSymlink: false, partial: false,
                                             fileID: fileID, parentID: work.dirID))
            }
        default:
            accum.agg += size
            if keepChildren {
                accum.files.append(ChildFile(name: entry.name, size: size, itemCount: 0,
                                             isSymlink: false, partial: false,
                                             fileID: fileID, parentID: work.dirID))
            }
        }
    }

    /// A dir is done once read and all queued children finalized; then it reports its
    /// totals into the parent (or the root entry list) and may finish the parent too.
    /// Called under the shared lock; cascades stay on one thread (depth = dir depth).
    private func finish(_ work: DirWork, state: ScanState, keepTree: Bool) {
        guard !work.finalized, work.read, work.pendingChildren == 0 else { return }
        work.finalized = true
        if keepTree {
            var top = work.largeCandidates
            sortTop(&top)
            work.node = AnalyzeNode(
                path: work.path, name: work.name, size: work.ownEntry + work.agg,
                childrenTotal: work.agg, itemCount: work.count, partial: work.partial,
                identity: PathIdentity(parent: work.parent?.dirID, target: work.dirID),
                isOtherDevice: work.otherDevice, collected: work.collect,
                dirs: work.subdirs.compactMap(\.node), files: work.files, topFiles: top)
        }
        work.subdirs = []
        state.liveDirs -= 1
        if state.liveDirs == 0 { state.lock.broadcast() }
        guard let parent = work.parent else { return }
        parent.agg += work.ownEntry + work.agg
        parent.count += work.count
        parent.partial = parent.partial || work.partial
        merge(&parent.largeCandidates, work.largeCandidates)
        parent.pendingChildren -= 1
        if parent.isRoot { state.rootDirs.append(work) }
        if parent.read, parent.pendingChildren == 0 {
            finish(parent, state: state, keepTree: keepTree)
        }
    }

    // MARK: getattrlistbulk

    /// stat that follows the link: true when a symlink resolves to a directory.
    static func isDirTarget(_ path: String) -> Bool {
        var st = stat()
        return followStat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Attributes fetched per entry: name + vnode type + ids + per-entry error (common),
    /// mount status (dir), link count + sizes (file). Returned fields follow ascending
    /// bit order within each group; groups arrive common → vol → dir → file → fork.
    private static let bulkAttrs: attrlist = {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = ATTR_CMN_RETURNED_ATTRS | ag(ATTR_CMN_NAME) | ag(ATTR_CMN_DEVID)
            | ag(ATTR_CMN_OBJTYPE) | ag(ATTR_CMN_FILEID) | ag(ATTR_CMN_ERROR)
        al.dirattr = ag(ATTR_DIR_MOUNTSTATUS)
        al.fileattr = ag(ATTR_FILE_LINKCOUNT) | ag(ATTR_FILE_ALLOCSIZE)
            | ag(ATTR_FILE_DATALENGTH)
        return al
    }()

    private static func ag(_ v: Int32) -> attrgroup_t { attrgroup_t(bitPattern: v) }

    /// Decode one entry at `off` (advanced to the next record).
    private static func parseEntry(_ raw: UnsafeBufferPointer<CChar>,
                                   at off: inout Int) -> BulkEntry {
        var e = BulkEntry()
        guard let base = raw.baseAddress else { return e }
        let entry = base + off
        e.error = true
        let len = Int(UnsafeRawPointer(entry).load(as: UInt32.self))
        defer { off += len }

        guard len >= 4 + MemoryLayout<attribute_set_t>.size else { return e }

        var aset = attribute_set_t()
        memcpy(&aset, entry + 4, MemoryLayout<attribute_set_t>.size)
        var p = entry + 4 + MemoryLayout<attribute_set_t>.size

        var nameStart = entry + len
        if aset.commonattr & ag(ATTR_CMN_NAME) != 0 {
            var ref = attrreference_t()
            memcpy(&ref, p, MemoryLayout<attrreference_t>.size)
            nameStart = p + Int(ref.attr_dataoffset)
            var bytes = UnsafeRawBufferPointer(start: nameStart, count: Int(ref.attr_length))
            if bytes.last == 0 { bytes = UnsafeRawBufferPointer(rebasing: bytes.dropLast()) }
            e.name = String(decoding: bytes, as: UTF8.self)
            p += MemoryLayout<attrreference_t>.size
        }
        if aset.commonattr & ag(ATTR_CMN_DEVID) != 0 {
            memcpy(&e.dev, p, 4); p += 4
        }
        if aset.commonattr & ag(ATTR_CMN_OBJTYPE) != 0 {
            memcpy(&e.objtype, p, 4); p += 4
        }
        if aset.commonattr & ag(ATTR_CMN_FILEID) != 0 {
            memcpy(&e.ino, p, 8); p += 8
        }
        if aset.dirattr & ag(ATTR_DIR_MOUNTSTATUS) != 0 {
            var flags: UInt32 = 0
            memcpy(&flags, p, 4); p += 4
            e.mountPoint = flags & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
        }
        if aset.fileattr & ag(ATTR_FILE_LINKCOUNT) != 0 {
            memcpy(&e.nlink, p, 4); p += 4
        }
        if aset.fileattr & ag(ATTR_FILE_ALLOCSIZE) != 0 {
            memcpy(&e.allocSize, p, 8); p += 8
        }
        if aset.fileattr & ag(ATTR_FILE_DATALENGTH) != 0 {
            memcpy(&e.dataLength, p, 8); p += 8
        }
        // ATTR_CMN_ERROR (requested) is only written by the kernel when the returned-attrs
        // bit is set; reading 4 bytes when errBit is false would read into the name data
        // or alignment padding and could falsely mark a healthy entry as partial
        let errBit = aset.commonattr & ag(ATTR_CMN_ERROR) != 0
        var code: UInt32 = 0
        if errBit, p + 4 <= nameStart {
            memcpy(&code, p, 4)
            p += 4
        }
        e.error = errBit || code != 0
        return e
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
