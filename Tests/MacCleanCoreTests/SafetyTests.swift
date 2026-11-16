import Foundation
import Testing
@testable import MacCleanCore

private let home = NSHomeDirectory()
private let protection = ProtectionPolicy(home: home, ownLogDirectory: home + "/Library/Logs/MacClean")
private let policy = PathPolicy(home: home, protection: protection)
private let idleProbes = ProbeContext(
    processes: ProcessSnapshot(entries: [], bundleIDs: [], complete: true),
    openFiles: OpenFilesSnapshot(paths: [], complete: true)
)

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "macclean-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct PathPolicyTests {
    @Test func normalize() {
        #expect(PathPolicy.normalize("/a//b/./c/") == "/a/b/c")
        #expect(PathPolicy.normalize("/a/b/.") == "/a/b")
        #expect(PathPolicy.normalize("/") == "/")
    }

    @Test(arguments: ["/", "/System", "/System/Library/Caches", "/usr/bin", "/Library", "/Library/Keychains/x",
                      "/Applications", "/Applications/Safari.app/Contents", "/Users", "/Users/Shared", home,
                      "/private/var/folders", "/etc/hosts", "/private/tmp", "/opt/homebrew"])
    func criticalPaths(_ path: String) {
        #expect(PathPolicy.isCritical(path))
    }

    @Test(arguments: ["/usr/local/lib/foo", "/opt/homebrew/Cellar/x", "/Library/Caches/foo",
                      home + "/Library/Caches/foo"])
    func nonCriticalPaths(_ path: String) {
        #expect(!PathPolicy.isCritical(path))
    }

    @Test func caseAliasIsCritical() {
        // APFS is case-insensitive: /SYSTEM is the same directory as /System.
        #expect(PathPolicy.isCritical("/SYSTEM/Library"))
    }

    @Test func rejectsMalformedPaths() {
        #expect(policy.validate("", probes: idleProbes) == .emptyPath)
        #expect(policy.validate("relative/path", probes: idleProbes) == .notAbsolute)
        #expect(policy.validate(home + "/Library/../x", probes: idleProbes) == .parentTraversal)
        #expect(policy.validate(home + "/Library/Caches/a\nb", probes: idleProbes) == .controlCharacter)
        // `..` inside a name is allowed
        #expect(policy.validate(home + "/Library/Caches/name..files", probes: idleProbes) == nil)
    }

    @Test func protectsUserData() {
        #expect(policy.validate(home + "/Library/Keychains/login.keychain-db", probes: idleProbes) == .protected)
        #expect(policy.validate(home + "/Library/Mobile Documents/x", probes: idleProbes) == .protected)
        #expect(policy.validate(home + "/.config", probes: idleProbes) == .protected)
        #expect(policy.validate(home + "/Library/Caches/com.apple.Safari", probes: idleProbes) == .protected)
        #expect(policy.validate(home + "/Library/Caches/com.1password.1password", probes: idleProbes) == .protected)
        #expect(policy.validate(home + "/Library/Logs/MacClean/operations.log", probes: idleProbes) == .protected)
    }

    @Test func containerCachesAllowedButContainerDataProtected() {
        let base = home + "/Library/Containers/com.tinyspeck.slackmacgap/Data"
        #expect(policy.validate(base + "/Library/Caches/x", probes: idleProbes) == nil)
        #expect(policy.validate(home + "/Library/Containers/com.apple.mail/Data/Library/Mail", probes: idleProbes)
                == .protected)
    }

    @Test func liveCacheOfRunningAppRefused() {
        let running = ProbeContext(
            processes: ProcessSnapshot(entries: [], bundleIDs: ["com.example.app"], complete: true),
            openFiles: OpenFilesSnapshot(paths: [], complete: true))
        #expect(policy.validate(home + "/Library/Caches/com.example.app/data", probes: running) == .liveUserCache)
        let unknown = ProbeContext(
            processes: ProcessSnapshot(entries: [], bundleIDs: [], complete: false),
            openFiles: OpenFilesSnapshot(paths: [], complete: true))
        #expect(policy.validate(home + "/Library/Caches/com.example.app/data", probes: unknown) == .liveUserCache)
        #expect(policy.validate(home + "/Library/Caches/com.example.app/data", probes: idleProbes) == nil)
    }

    @Test func cacheOwnerMatchesHelperByLeafAndVendor() {
        let entry = ProcessSnapshot.Entry(pid: 10, name: "ShipIt", path: "/Applications/Slack.app/x/ShipIt",
                                          arguments: "/Users/u/Library/Caches/tinyspeck-slackmacgap ShipIt")
        let snapshot = ProcessSnapshot(entries: [entry], bundleIDs: [], complete: true)
        #expect(snapshot.cacheOwnerState("com.tinyspeck.slackmacgap.ShipIt") == .running)
        #expect(snapshot.cacheOwnerState("com.other.vendor.Updater") == .notRunning)
    }

    @Test func openSQLiteRefused() {
        let db = home + "/Library/Caches/someapp/cache.db"
        let open = ProbeContext(processes: idleProbes.processes,
                                openFiles: OpenFilesSnapshot(paths: [db], complete: true))
        #expect(policy.validate(db + "-wal", probes: open) == .sqliteInUse)
    }

    @Test func symlinkToCriticalRefused() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let link = dir + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/System")
        #expect(policy.validate(link, probes: idleProbes) == .symlinkToCritical)
    }

    @Test func uninstallModeRefusesLibraryRoots() throws {
        // S1 defence in depth: even a normalized candidate equal to a Library root is refused
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let policy = PathPolicy(home: home,
                                protection: ProtectionPolicy(home: home,
                                                             ownLogDirectory: home + "/Library/Logs/MacClean"))
        for root in [home, home + "/Library", home + "/Library/Preferences",
                     home + "/Library/Preferences/ByHost", home + "/Library/Caches",
                     home + "/Library/Logs", home + "/Library/Containers",
                     home + "/Library/Group Containers", home + "/.config", home + "/.cache"] {
            #expect(policy.validate(root, probes: idleProbes, uninstall: true) != nil,
                    "root \(root) accepted")
        }
        #expect(policy.validate(home + "/Library/Preferences/com.example.Foo.plist",
                              probes: idleProbes, uninstall: true) == nil)
    }

    @Test func protectData() {
        #expect(protection.shouldProtectData("com.apple.anything"))
        #expect(protection.shouldProtectData("com.bitwarden.desktop"))
        #expect(protection.shouldProtectData("md.obsidian"))
        #expect(!protection.shouldProtectData("com.example.random"))
    }
}

@Suite struct WhitelistTests {
    @Test func defaultsWhenNoFile() throws {
        let wl = try Whitelist.load(file: URL(fileURLWithPath: "/nonexistent/whitelist"), home: "/Users/u")
        #expect(wl.patterns.contains("/Users/u/.gradle/caches/*"))
        #expect(wl.patterns.contains("/Users/u/Library/Caches/kitty"))
        #expect(wl.protectsFinderMetadata)
    }

    @Test func userFileReplacesDefaultsButKeepsSafety() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = URL(fileURLWithPath: dir + "/whitelist")
        try "# comment\n~/keep/this\nrelative/bad\n/System\n".write(to: file, atomically: true, encoding: .utf8)
        let wl = try Whitelist.load(file: file, home: "/Users/u")
        #expect(wl.patterns.contains("/Users/u/keep/this"))
        #expect(!wl.patterns.contains("/Users/u/.gradle/caches/*"))
        #expect(wl.patterns.contains("/Users/u/Library/Caches/kitty"))
        #expect(wl.rejected == ["relative/bad", "/System"])
    }

    @Test func unreadableFileFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(throws: Whitelist.LoadError.self) {
            _ = try Whitelist.load(file: URL(fileURLWithPath: dir), home: "/Users/u")
        }
    }

    @Test func matching() {
        let wl = Whitelist(expandedPatterns: ["/Users/u/Library/Caches/JetBrains*", "/Users/u/.gradle/caches",
                                              "/Users/u/a/b/c"])
        #expect(wl.contains("/Users/u/Library/Caches/JetBrains2024/x"))   // glob crosses '/'
        #expect(wl.contains("/Users/u/.gradle/caches/modules"))           // descendant of literal
        #expect(wl.contains("/Users/u/a"))                                // ancestor of protected child
        #expect(!wl.contains("/Users/u/Library/Caches/Other"))
    }
}

@Suite struct CleanEngineTests {
    private final class Counter: @unchecked Sendable { var value = 0 }

    private func engine(home: String, rules: [CleanRule] = CleanCatalog.rules) -> CleanEngine {
        let protection = ProtectionPolicy(home: home, ownLogDirectory: home + "/Library/Logs/MacClean")
        return CleanEngine(home: home,
                           deleter: SafeDeleter(policy: PathPolicy(home: home, protection: protection),
                                                whitelist: Whitelist(expandedPatterns: []), log: nil),
                           rules: rules)
    }

    @Test func guardedChildWinsOverUnguardedParent() throws {
        // S6: ~/Library/Logs/* must not claim CoreSimulator, which a later guarded rule owns
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(
            atPath: home + "/Library/Logs/CoreSimulator", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: home + "/Library/Logs/FooApp", withIntermediateDirectories: true)
        let rules = [
            CleanRule(.userEssentials, "logs", ["~/Library/Logs/*"], source: "t"),
            CleanRule(.developerTools, "sim", ["~/Library/Logs/CoreSimulator/*"], source: "t",
                      whenNotRunning: RunningGuard(names: ["Simulator"])),
        ]
        let unguarded = engine(home: home, rules: rules).candidates(for: rules[0])
        #expect(unguarded.contains(home + "/Library/Logs/FooApp"))
        #expect(!unguarded.contains(home + "/Library/Logs/CoreSimulator"))
    }

    @Test func catalogCachesRuleSkipsGuardedXcode() throws {
        // S6: same check against the real catalog (Xcode cache rule is guarded)
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(
            atPath: home + "/Library/Caches/com.apple.dt.Xcode", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: home + "/Library/Caches/FooApp", withIntermediateDirectories: true)
        let e = engine(home: home)
        let rule = try #require(CleanCatalog.rules.first { $0.label == "User app cache" })
        let candidates = e.candidates(for: rule)
        #expect(!candidates.contains(home + "/Library/Caches/com.apple.dt.Xcode"))
        #expect(candidates.contains(home + "/Library/Caches/FooApp"))
    }

    @Test func executeRecapturesProbesPerRule() throws {
        // S7: fresh probe state per rule group, not one snapshot for the whole run
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let f1 = home + "/Library/Logs/a.log"
        let f2 = home + "/Library/Caches/b.bin"
        for f in [f1, f2] {
            try FileManager.default.createDirectory(
                atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: 8).write(to: URL(fileURLWithPath: f))
        }
        let rules = [
            CleanRule(.userEssentials, "r1", ["~/Library/Logs/*"], source: "t"),
            CleanRule(.appCaches, "r2", ["~/Library/Caches/*"], source: "t"),
        ]
        var e = engine(home: home, rules: rules)
        let counter = Counter()
        e.captureProbes = { counter.value += 1; return idleProbes }
        let items = [f1, f2].enumerated().map { i, f in
            CleanItem(path: f, ruleID: rules[i].id, size: .zero, identity: PathIdentity.capture(f))
        }
        _ = e.execute(items)
        #expect(counter.value == 2)
    }

    @Test func guardedRuleReprobedBeforeDelete() throws {
        // S7: a guard that turns "running" after the scan must still block its items
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let f = home + "/Library/Caches/target.bin"
        try FileManager.default.createDirectory(
            atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(count: 8).write(to: URL(fileURLWithPath: f))
        let rules = [CleanRule(.developerTools, "sim", ["~/Library/Caches/*"], source: "t",
                               whenNotRunning: RunningGuard(names: ["Simulator"]))]
        var e = engine(home: home, rules: rules)
        e.captureProbes = {
            ProbeContext(processes: ProcessSnapshot(
                entries: [ProcessSnapshot.Entry(pid: 1, name: "Simulator",
                                              path: "/x/Simulator", arguments: "")],
                bundleIDs: [], complete: true),
            openFiles: OpenFilesSnapshot(paths: [], complete: true))
        }
        let item = CleanItem(path: f, ruleID: rules[0].id, size: .zero,
                             identity: PathIdentity.capture(f))
        let result = e.execute([item])
        #expect(result.skipped.map(\.path) == [f])
        #expect(FileStat.exists(f))
    }
}

@Suite struct ProbeAndShellTests {
    @Test func openFilesOnlyBenignErrnos() {
        // S8: ESRCH (process gone) / EPERM (other user) are the only tolerable probe failures
        #expect(OpenFilesSnapshot.isBenignProbeError(ESRCH))
        #expect(OpenFilesSnapshot.isBenignProbeError(EPERM))
        #expect(!OpenFilesSnapshot.isBenignProbeError(EIO))
        #expect(!OpenFilesSnapshot.isBenignProbeError(0))
    }

    @Test func cpuTickDeltaSurvivesCounterWrap() {
        // O4: subtract wrapped UInt32 counters before widening
        #expect(CPUSampler.tickDelta(5, UInt32.max - 3) == 9)
        #expect(CPUSampler.tickDelta(10, 3) == 7)
    }

    @Test func timeoutKillsStubbornProcess() async throws {
        // O5: SIGTERM is ignored → SIGKILL must reap the child before its marker appears
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let marker = dir + "/survived"
        let r = Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 3; touch '\(marker)'"],
                          timeout: 0.3)
        #expect(r.timedOut)
        try await Task.sleep(nanoseconds: 4_000_000_000)
        #expect(!FileStat.exists(marker))
    }
}

@Suite struct DeleterTests {
    private func deleter(whitelist: [String] = []) -> SafeDeleter {
        SafeDeleter(policy: policy, whitelist: Whitelist(expandedPatterns: whitelist), log: nil)
    }

    @Test func dryRunKeepsFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/cache.bin"
        try Data(count: 10_000).write(to: URL(fileURLWithPath: file))
        let outcome = deleter().remove(file, expected: nil, dryRun: true, probes: idleProbes)
        guard case .wouldRemove(let size) = outcome else { Issue.record("\(outcome)"); return }
        #expect(size.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func removesDirectoryRecursively() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = dir + "/cache"
        try FileManager.default.createDirectory(atPath: target + "/nested", withIntermediateDirectories: true)
        try Data(count: 5000).write(to: URL(fileURLWithPath: target + "/nested/f"))
        let id = PathIdentity.capture(target)
        let outcome = deleter().remove(target, expected: id, dryRun: false, probes: idleProbes)
        guard case .removed = outcome else { Issue.record("\(outcome)"); return }
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func symlinkRemovalKeepsTarget() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        try Data(count: 10).write(to: URL(fileURLWithPath: dir + "/real/keep"))
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/real")
        _ = deleter().remove(dir + "/link", expected: nil, dryRun: false, probes: idleProbes)
        #expect(!FileStat.exists(dir + "/link"))
        #expect(FileManager.default.fileExists(atPath: dir + "/real/keep"))
    }

    @Test func identityChangeSkips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/f"
        try Data(count: 10).write(to: URL(fileURLWithPath: file))
        let id = PathIdentity.capture(file)
        try FileManager.default.removeItem(atPath: file)
        try Data(count: 20).write(to: URL(fileURLWithPath: file))   // replaced object
        let outcome = deleter().remove(file, expected: id, dryRun: false, probes: idleProbes)
        #expect(outcome == .skipped(.identityChanged))
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func whitelistSkips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/f"
        try Data(count: 10).write(to: URL(fileURLWithPath: file))
        let outcome = deleter(whitelist: [dir + "/*"]).remove(file, expected: nil, dryRun: false, probes: idleProbes)
        #expect(outcome == .skipped(.whitelist))
    }

    @Test func hardLinksCountedOnce() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(count: 100_000).write(to: URL(fileURLWithPath: dir + "/a"))
        try FileManager.default.linkItem(atPath: dir + "/a", toPath: dir + "/b")
        let both = SizeCalculator.allocatedSize(of: dir).bytes
        let one = SizeCalculator.allocatedSize(of: dir + "/a").bytes
        #expect(both < one * 2)
    }
}
