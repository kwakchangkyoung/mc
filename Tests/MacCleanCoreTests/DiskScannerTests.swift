import Foundation
import Testing
@testable import MacCleanCore

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "macclean-analyze-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private let idleProbes = ProbeContext(
    processes: ProcessSnapshot(entries: [], bundleIDs: [], complete: true),
    openFiles: OpenFilesSnapshot(paths: [], complete: true)
)

@Suite struct DiskScannerTests {
    @Test func sortsChildrenBySizeDescending() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(count: 1_000).write(to: URL(fileURLWithPath: dir + "/small"))
        try Data(count: 200_000).write(to: URL(fileURLWithPath: dir + "/big"))
        try FileManager.default.createDirectory(atPath: dir + "/dir", withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: URL(fileURLWithPath: dir + "/dir/f"))

        let r = try DiskScanner().scan(dir)
        #expect(r.entries.map(\.name) == ["big", "dir", "small"])
        let d = try #require(r.entries.first { $0.name == "dir" })
        #expect(d.isDir && d.itemCount == 1)          // only f; dirs are not counted
        #expect(r.totalFiles == 3)
        #expect(r.totalSize == r.entries.reduce(0) { $0 + $1.size })
    }

    @Test func symlinkNotFollowed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: URL(fileURLWithPath: dir + "/real/f"))
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/real")

        let r = try DiskScanner().scan(dir)
        let link = try #require(r.entries.first { $0.name == "link" })
        #expect(link.isSymlink)
        #expect(link.isDir)            // dir target is drillable, like Mole's "name →"
        #expect(link.itemCount == 0)
        #expect(link.size < 4_096)     // the link itself, not the target contents
        let real = try #require(r.entries.first { $0.name == "real" })
        #expect(real.size >= 200_000)
    }

    @Test func hardLinksCountedOnce() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(count: 200_000).write(to: URL(fileURLWithPath: dir + "/a"))
        try FileManager.default.linkItem(atPath: dir + "/a", toPath: dir + "/b")

        let r = try DiskScanner().scan(dir)
        #expect(r.totalSize < 200_000 * 2)
        #expect(r.entries.contains { $0.size == 0 })   // second link counts nothing
    }

    @Test func hardLinksAcrossDirectoriesCountedOnce() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/x", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/y", withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: URL(fileURLWithPath: dir + "/x/f"))
        try FileManager.default.linkItem(atPath: dir + "/x/f", toPath: dir + "/y/f")

        let r = try DiskScanner().scan(dir)
        let x = try #require(r.entries.first { $0.name == "x" })
        let y = try #require(r.entries.first { $0.name == "y" })
        // scan-order dependent which child keeps the bytes (Mole behaves the same)
        #expect(x.size == 0 || y.size == 0)
        #expect(r.totalSize < 200_000 * 2)
    }

    @Test func largeFilesSkipCodeExtensionsAndFoldedDirs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: dir + "/video.mp4"))
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: dir + "/code.swift"))
        try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/tiny.bin"))
        try FileManager.default.createDirectory(atPath: dir + "/repo/.git", withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: dir + "/repo/.git/pack.pack"))

        let r = try DiskScanner().scan(dir)
        #expect(r.largeFiles.map(\.name) == ["video.mp4"])
    }

    @Test func cancellationStopsScan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(count: 100).write(to: URL(fileURLWithPath: dir + "/f"))
        let token = ScanCancellation()
        token.cancel()
        let r = try DiskScanner().scan(dir, cancellation: token)
        #expect(r.cancelled)
        #expect(r.entries.isEmpty)
    }

    @Test func errors() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/f"
        try Data(count: 10).write(to: URL(fileURLWithPath: file))
        #expect(throws: AnalyzeError.self) { _ = try DiskScanner().scan(dir + "/missing") }
        #expect(throws: AnalyzeError.self) { _ = try DiskScanner().scan(file) }
    }

    /// Nested dirs, cross-dir hard links, a dir symlink and a folded dir.
    private func makeFixture() throws -> String {
        let dir = try makeTempDir()
        try Data(count: 100_000).write(to: URL(fileURLWithPath: dir + "/plain"))
        try FileManager.default.createDirectory(atPath: dir + "/a/b", withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: URL(fileURLWithPath: dir + "/a/f"))
        try Data(count: 30_000).write(to: URL(fileURLWithPath: dir + "/a/b/g"))
        try FileManager.default.createDirectory(atPath: dir + "/repo/node_modules", withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: dir + "/repo/node_modules/big.bin"))
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: dir + "/repo/video.mp4"))
        try FileManager.default.createDirectory(atPath: dir + "/x", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/y", withIntermediateDirectories: true)
        try Data(count: 60_000).write(to: URL(fileURLWithPath: dir + "/x/hl"))
        try FileManager.default.linkItem(atPath: dir + "/x/hl", toPath: dir + "/y/hl")
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/a")
        return dir
    }

    /// Independent serial reference: contentsOfDirectory + lstat, same scan rules as Mole.
    private func refScan(_ dir: String, rootDev: dev_t, seen: inout Set<FileID>,
                         collect: Bool) -> (size: Int64, files: Int, top: [(path: String, size: Int64)]) {
        var out = (size: Int64(0), files: 0, top: [(path: String, size: Int64)]())
        var st = stat()
        guard lstat(dir, &st) == 0 else { return out }
        out.size += min(Int64(st.st_blocks) * 512, st.st_size)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            let p = dir + "/" + name
            var cs = stat()
            guard lstat(p, &cs) == 0 else { continue }
            let own = min(Int64(cs.st_blocks) * 512, cs.st_size)
            switch cs.st_mode & S_IFMT {
            case S_IFDIR:
                guard cs.st_dev == rootDev else { out.size += own; continue }
                let sub = refScan(p, rootDev: rootDev, seen: &seen,
                                  collect: collect && !DiskScanner.foldedDirs.contains(name))
                out.size += sub.size; out.files += sub.files; out.top += sub.top
            case S_IFREG:
                if collect { out.files += 1 }
                var size = own
                if cs.st_nlink > 1 {
                    let id = FileID(dev: UInt64(UInt32(bitPattern: cs.st_dev)), ino: UInt64(cs.st_ino))
                    if !seen.insert(id).inserted { size = 0 }
                }
                out.size += size
                if collect, size >= 1_000_000,
                   !DiskScanner.skipExtensions.contains((p as NSString).pathExtension.lowercased()) {
                    out.top.append((p, size))
                }
            default:
                out.size += own
            }
        }
        return out
    }

    @Test func parallelMatchesSerialReference() throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var st = stat()
        try #require(lstat(dir, &st) == 0)

        var seen = Set<FileID>()
        var expected = [String: (size: Int64, files: Int)]()
        var totalFiles = 0
        var top: [(path: String, size: Int64)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
            let p = dir + "/" + name
            var cs = stat()
            try #require(lstat(p, &cs) == 0)
            if cs.st_mode & S_IFMT == S_IFDIR {
                let sub = refScan(p, rootDev: st.st_dev, seen: &seen, collect: true)
                expected[name] = (sub.size, sub.files)
                totalFiles += sub.files
                top += sub.top
            } else {
                var size = min(Int64(cs.st_blocks) * 512, cs.st_size)
                if cs.st_nlink > 1 {
                    let id = FileID(dev: UInt64(UInt32(bitPattern: cs.st_dev)), ino: UInt64(cs.st_ino))
                    if !seen.insert(id).inserted { size = 0 }
                }
                expected[name] = (size, cs.st_mode & S_IFMT == S_IFREG ? 1 : 0)
                if cs.st_mode & S_IFMT == S_IFREG { totalFiles += 1 }
                if size >= 1_000_000,
                   !DiskScanner.skipExtensions.contains((p as NSString).pathExtension.lowercased()) {
                    top.append((p, size))
                }
            }
        }

        let r = try DiskScanner().scan(dir)
        #expect(r.entries.count == expected.count)
        #expect(r.totalFiles == totalFiles)
        #expect(r.totalSize == expected.values.reduce(0) { $0 + $1.size })
        for e in r.entries {
            let want = try #require(expected[e.name], "\(e.name)")
            #expect(e.itemCount == want.files, "\(e.name)")
            // which of a hard-link pair keeps the bytes is order-dependent, so the
            // linked dirs x/y are compared as an aggregate below
            if e.name != "x" && e.name != "y" {
                #expect(e.size == want.size, "\(e.name)")
            }
        }
        #expect(r.entries.filter { $0.name == "x" || $0.name == "y" }.map(\.size).sorted()
                == [expected["x"]!.size, expected["y"]!.size].sorted())
        // folded dirs are not enumerated: node_modules content counts toward size only
        let repo = try #require(r.entries.first { $0.name == "repo" })
        #expect(repo.itemCount == 1)          // video.mp4 only
        #expect(Set(r.largeFiles.map(\.path)) == Set(top.map { $0.path }))
    }

    @Test func oneWorkerMatchesMany() throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var serial = DiskScanner()
        serial.workerCount = 1
        let one = try serial.scan(dir)
        let many = try DiskScanner().scan(dir)
        // which sibling keeps a hard link's bytes is order-dependent (as in Mole), so
        // compare the multiset of sizes rather than per-name sizes
        #expect(one.entries.map(\.name).sorted() == many.entries.map(\.name).sorted())
        #expect(one.entries.map(\.size).sorted() == many.entries.map(\.size).sorted())
        #expect(one.entries.map(\.itemCount).sorted() == many.entries.map(\.itemCount).sorted())
        #expect(one.totalSize == many.totalSize)
        #expect(one.totalFiles == many.totalFiles)
        #expect(one.largeFiles.map(\.path) == many.largeFiles.map(\.path))
        #expect(one.partial == many.partial)
    }

    @Test func keptTreeDrillInMatchesFreshScan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/a/b", withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: URL(fileURLWithPath: dir + "/a/f"))
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: dir + "/a/b/big.mp4"))
        try Data(count: 10_000).write(to: URL(fileURLWithPath: dir + "/a/b/small"))
        try FileManager.default.createSymbolicLink(atPath: dir + "/a/link", withDestinationPath: dir + "/a/b")

        let cached = try DiskScanner().scan(dir, keepTree: true)
        let fresh = try DiskScanner().scan(dir + "/a")
        let node = try #require(cached.tree?.dirs.first { $0.name == "a" })
        let drilled = node.asResult()
        #expect(drilled.totalSize == fresh.totalSize)
        #expect(drilled.totalFiles == fresh.totalFiles)
        #expect(drilled.partial == fresh.partial)
        #expect(drilled.entries.map(\.path) == fresh.entries.map(\.path))
        for (a, b) in zip(drilled.entries, fresh.entries) {
            #expect(a.size == b.size)
            #expect(a.isDir == b.isDir)
            #expect(a.isSymlink == b.isSymlink)
            #expect(a.itemCount == b.itemCount)
        }
        #expect(drilled.largeFiles.map(\.path) == fresh.largeFiles.map(\.path))
    }
}

@Suite struct TrashTests {
    private func deleter() -> SafeDeleter {
        let home = NSHomeDirectory()
        let protection = ProtectionPolicy(home: home, ownLogDirectory: home + "/Library/Logs/MacClean")
        return SafeDeleter(policy: PathPolicy(home: home, protection: protection),
                           whitelist: Whitelist(expandedPatterns: []), log: nil)
    }

    @Test func trashMovesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/f"
        try Data(count: 100).write(to: URL(fileURLWithPath: file))
        let outcome = deleter().trash(file, expected: nil, probes: idleProbes)
        guard case .removed = outcome else { Issue.record("\(outcome)"); return }
        #expect(!FileStat.exists(file))
    }

    @Test func trashRefusesProtectedPath() {
        #expect(deleter().trash("/System", expected: nil, probes: idleProbes)
                == .skipped(.criticalPath))
    }

    @Test func trashMissingPath() {
        #expect(deleter().trash("/nonexistent/nope", expected: nil, probes: idleProbes) == .missing)
    }
}

@Suite struct TreemapLayoutTests {
    @Test func squarifiedTreemapNestsSubdirectoriesAndHitTests() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/big/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/small", withIntermediateDirectories: true)
        try Data(count: 64 * 1024).write(to: URL(fileURLWithPath: dir + "/big/sub/a.bin"))
        try Data(count: 32 * 1024).write(to: URL(fileURLWithPath: dir + "/big/b.bin"))
        try Data(count: 16 * 1024).write(to: URL(fileURLWithPath: dir + "/small/c.bin"))

        let result = try DiskScanner().scan(dir, keepTree: true)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        let cells = TreemapLayout.compute(result: result, in: bounds, maxDepth: 2)

        #expect(cells.count == 2)
        let bigCell = try #require(cells.first { $0.name == "big" })
        let smallCell = try #require(cells.first { $0.name == "small" })
        #expect(bigCell.rect.width * bigCell.rect.height > smallCell.rect.width * smallCell.rect.height)
        #expect(!bigCell.children.isEmpty)

        // Hit-testing inside a nested child returns the nested child cell with topLevelPath == bigCell.path
        let child = try #require(bigCell.children.first)
        let center = CGPoint(x: child.rect.midX, y: child.rect.midY)
        let hit = try #require(TreemapLayout.hitTest(cells, at: center))
        #expect(hit.topLevelPath == bigCell.path)
        #expect(hit.depth >= 1)
    }
}
