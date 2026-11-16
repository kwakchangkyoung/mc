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
