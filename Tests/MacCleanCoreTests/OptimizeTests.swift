import Foundation
import Testing
@testable import MacCleanCore

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "macclean-optimize-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private let idleProbes = ProbeContext(
    processes: ProcessSnapshot(entries: [], bundleIDs: [], complete: true),
    openFiles: OpenFilesSnapshot(paths: [], complete: true)
)

private func mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func touch(_ path: String, _ data: Data = Data(count: 8)) throws {
    try mkdir((path as NSString).deletingLastPathComponent)
    try data.write(to: URL(fileURLWithPath: path))
}

private func makeDeleter(home: String) -> SafeDeleter {
    let protection = ProtectionPolicy(home: home, ownLogDirectory: home + "/Library/Logs/MacClean")
    return SafeDeleter(policy: PathPolicy(home: home, protection: protection),
                       whitelist: Whitelist(expandedPatterns: []), log: nil)
}

private func makeEngine(home: String, whitelist: OptimizeWhitelist = OptimizeWhitelist(ids: []),
                        shell: @escaping OptimizeEngine.Runner = { Shell.run($0, $1, timeout: $2) })
    -> OptimizeEngine {
    OptimizeEngine(home: home, deleter: makeDeleter(home: home), whitelist: whitelist, shell: shell)
}

private final class Recorder: @unchecked Sendable {
    var calls: [(String, [String])] = []
}

@Suite struct OptimizeCatalogTests {
    @Test func catalogMatchesDoc() {
        #expect(OptimizeTask.allCases.map(\.id) == [
            "cache_refresh", "saved_state_cleanup", "fix_broken_configs", "network_optimization",
            "sqlite_vacuum", "prevent_network_dsstore", "legacy_overrides_audit",
            "network_stack_optimize", "disk_permissions_repair", "spotlight_index_optimize",
            "spotlight_orphan_rules_cleanup", "periodic_maintenance", "shared_file_list_repair",
            "disk_verify", "login_items_audit", "quarantine_cleanup", "launch_agents_cleanup",
            "notification_cleanup", "coreduet_cleanup",
        ])
        #expect(OptimizeTask.allCases.count == 19)
    }

    @Test func adminTasks() {
        #expect(Set(OptimizeTask.allCases.filter(\.requiresAdmin)) == [
            .networkOptimization, .networkStackOptimize, .diskPermissionsRepair,
            .spotlightIndexOptimize, .periodicMaintenance,
        ])
    }

    @Test func outcomeKindCount() {
        #expect(OptimizeOutcomeKind.allCases.count == 6)
    }
}

@Suite struct OptimizeWhitelistTests {
    @Test func loadParsesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = URL(fileURLWithPath: dir + "/whitelist_optimize")
        try "# comment\n\ncache_refresh\n system_maintenance \n"
            .write(to: file, atomically: true, encoding: .utf8)
        let wl = OptimizeWhitelist.load(file: file)
        #expect(wl.contains(.cacheRefresh))
        #expect(wl.contains(.networkOptimization))   // legacy id "system_maintenance"
        #expect(!wl.contains(.savedStateCleanup))
    }

    @Test func missingFileIsEmpty() {
        let wl = OptimizeWhitelist.load(file: URL(fileURLWithPath: "/nonexistent/wl"))
        #expect(wl.ids.isEmpty)
    }

    @Test func whitelistedTaskIsSkippedWithoutRunning() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try mkdir(home + "/Library/Caches/com.apple.iconservices")
        let recorder = Recorder()
        let engine = makeEngine(home: home, whitelist: OptimizeWhitelist(ids: ["cache_refresh"])) {
            e, a, _ in recorder.calls.append((e, a)); return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(.cacheRefresh, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .skipped)
        #expect(recorder.calls.isEmpty)
        #expect(FileStat.exists(home + "/Library/Caches/com.apple.iconservices"))
    }
}

@Suite struct OptimizeEngineTests {
    @Test(arguments: [OptimizeTask.networkOptimization, .networkStackOptimize,
                      .diskPermissionsRepair, .spotlightIndexOptimize, .periodicMaintenance])
    func adminTasksNeverExecute(task: OptimizeTask) throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recorder = Recorder()
        let engine = makeEngine(home: home) { e, a, _ in
            recorder.calls.append((e, a)); return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(task, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .unavailable)
        #expect(recorder.calls.isEmpty)
    }

    @Test func dryRunDeletesNothing() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let state = home + "/Library/Saved Application State/com.example.Old.savedState"
        try mkdir(state)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: state)
        try touch(home + "/Library/Preferences/com.example.broken.plist", Data("not a plist".utf8))

        let engine = makeEngine(home: home)
        let saved = engine.run(.savedStateCleanup, dryRun: true, probes: idleProbes)
        let configs = engine.run(.fixBrokenConfigs, dryRun: true, probes: idleProbes)

        #expect(saved.kind == .applied)
        #expect(configs.kind == .applied)
        #expect(FileStat.exists(state))
        #expect(FileStat.exists(home + "/Library/Preferences/com.example.broken.plist"))
    }

    @Test func savedStateCleanupRemovesOnlyOldDirs() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let old = home + "/Library/Saved Application State/com.example.Old.savedState"
        let fresh = home + "/Library/Saved Application State/com.example.New.savedState"
        try mkdir(old)
        try mkdir(fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: old)

        let outcome = makeEngine(home: home).run(.savedStateCleanup, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .applied)
        #expect(!FileStat.exists(old))
        #expect(FileStat.exists(fresh))
    }

    @Test func fixBrokenConfigsRemovesOnlyBrokenThirdParty() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let prefs = home + "/Library/Preferences"
        // "{" is a genuinely invalid plist; a bare word like "garbage" lints OK (OpenStep)
        try touch(prefs + "/com.example.broken.plist", Data("{".utf8))
        try touch(prefs + "/com.apple.broken.plist", Data("{".utf8))                // Apple → keep
        try touch(prefs + "/loginwindow.plist", Data("{".utf8))                    // top-level → keep
        try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: prefs + "/com.example.ok.plist"))
        try touch(prefs + "/ByHost/com.example.brokenbyhost.plist", Data("{".utf8))

        let outcome = makeEngine(home: home).run(.fixBrokenConfigs, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .applied)
        #expect(!FileStat.exists(prefs + "/com.example.broken.plist"))
        #expect(!FileStat.exists(prefs + "/ByHost/com.example.brokenbyhost.plist"))
        #expect(FileStat.exists(prefs + "/com.apple.broken.plist"))
        #expect(FileStat.exists(prefs + "/loginwindow.plist"))
        #expect(FileStat.exists(prefs + "/com.example.ok.plist"))
    }

    @Test func launchAgentsCleanupReportsOnlyMissingPrograms() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let agents = home + "/Library/LaunchAgents"
        try mkdir(agents)
        let plists: [String: [String: Any]] = [
            "com.broken.agent.plist": ["Program": "/nonexistent/tool"],
            "com.ok.agent.plist": ["Program": "/bin/sh"],
            "com.volume.agent.plist": ["Program": "/Volumes/definitely-not-mounted-x/tool"],
            "com.args.agent.plist": ["ProgramArguments": ["/nonexistent/tool2", "-x"]],
        ]
        for (name, dict) in plists {
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: agents + "/" + name))
        }
        let outcome = makeEngine(home: home).run(.launchAgentsCleanup, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .attention)
        #expect(outcome.detail.sorted() == ["com.args.agent.plist", "com.broken.agent.plist"])
    }

    @Test func legacyOverridesDeletesOnlyTruthyKeys() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recorder = Recorder()
        let engine = makeEngine(home: home) { e, a, _ in
            recorder.calls.append((e, a))
            if a == ["read", "-g", "NSAppSleepDisabled"] {
                return .init(status: 0, stdout: "1\n", timedOut: false)
            }
            if a.first == "read" { return .init(status: 1, stdout: "", timedOut: false) }
            return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(.legacyOverridesAudit, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .applied)
        #expect(recorder.calls.contains { $0.1 == ["delete", "-g", "NSAppSleepDisabled"] })
    }

    @Test func sqliteVacuumSkippedWhenAppRunning() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let probes = ProbeContext(
            processes: ProcessSnapshot(
                entries: [ProcessSnapshot.Entry(pid: 1, name: "Mail", path: "", arguments: "")],
                bundleIDs: [], complete: true),
            openFiles: OpenFilesSnapshot(paths: [], complete: true))
        let outcome = makeEngine(home: home).run(.sqliteVacuum, dryRun: true, probes: probes)
        #expect(outcome.kind == .skipped)
    }

    @Test func quarantineCleanupProtectedDBUnchanged() throws {
        // Mole tasks.sh:511 — should_protect_path → unchanged. 파일명이 com.apple.*이므로
        // QuarantineEventsV2는 모든 홈에서 보호되며 Mole은 항상 "already clean"을 보고한다.
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let db = home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        try mkdir((db as NSString).deletingLastPathComponent)
        _ = Shell.run("/usr/bin/sqlite3", [db, "CREATE TABLE LSQuarantineEvent(x TEXT);"
                                           + " INSERT INTO LSQuarantineEvent VALUES('a');"], timeout: 5)

        let engine = makeEngine(home: home)
        #expect(engine.run(.quarantineCleanup, dryRun: true, probes: idleProbes).kind == .unchanged)
        #expect(engine.run(.quarantineCleanup, dryRun: false, probes: idleProbes).kind == .unchanged)
        let count = Shell.run("/usr/bin/sqlite3",
                              [db, "SELECT COUNT(*) FROM LSQuarantineEvent;"], timeout: 5).stdout
        #expect(count.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test func sqliteVacuumSkipsProtectedDB() throws {
        // Mole tasks.sh:621 — DB별 should_protect_path. ~/Library/Mail/* 은 보호 경로.
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let mailDB = home + "/Library/Mail/V10/MailData/Envelope Index"
        let safariDB = home + "/Library/Safari/History.db"
        for db in [mailDB, safariDB] {
            try mkdir((db as NSString).deletingLastPathComponent)
            _ = Shell.run("/usr/bin/sqlite3", [db, "CREATE TABLE t(x);"], timeout: 5)
        }
        let recorder = Recorder()
        let engine = makeEngine(home: home) { e, a, _ in
            recorder.calls.append((e, a))
            let sql = a.last ?? ""
            if sql.hasPrefix("PRAGMA page_count") {
                return .init(status: 0, stdout: "100\n10\n", timedOut: false)   // freelist 10%
            }
            if sql.hasPrefix("PRAGMA integrity_check") {
                return .init(status: 0, stdout: "ok\n", timedOut: false)
            }
            return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(.sqliteVacuum, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .applied)
        let dbCalls = recorder.calls.compactMap { $0.1.first }
        #expect(!dbCalls.contains { $0.contains("/Library/Mail/") })
        #expect(dbCalls.contains(safariDB))
    }

    @Test func notificationCleanupUsesMacEpochCutoff() throws {
        // delivered_date는 Mac epoch(2001) — 실 DB에서 min 7.69e8, max 8.16e8 관측
        // (Unix 'now' ≈ 1.79e9). 컷오프는 strftime - strftime('2001-01-01') 이어야 한다.
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let db = home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
        try mkdir((db as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: db, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: db))
        try handle.truncate(atOffset: 51 * 1024 * 1024)   // ≥50MB, sparse
        try handle.close()

        let recorder = Recorder()
        let engine = makeEngine(home: home) { e, a, _ in
            recorder.calls.append((e, a))
            return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(.notificationCleanup, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .applied)
        let sql = recorder.calls.first { $0.0 == "/usr/bin/sqlite3" }?.1.last ?? ""
        #expect(sql.contains("strftime('%s','2001-01-01')"))
        #expect(sql.contains("delivered_date"))
    }

    @Test func outcomeCountsOrdering() {
        #expect(OptimizeOutcome.fromCounts(.cacheRefresh, applied: 1, failed: 1, skipped: 0,
                                           message: "x").kind == .failed)
        #expect(OptimizeOutcome.fromCounts(.cacheRefresh, applied: 1, failed: 0, skipped: 1,
                                           message: "x").kind == .applied)
        #expect(OptimizeOutcome.fromCounts(.cacheRefresh, applied: 0, failed: 0, skipped: 1,
                                           message: "x").kind == .skipped)
        #expect(OptimizeOutcome.fromCounts(.cacheRefresh, applied: 0, failed: 0, skipped: 0,
                                           message: "x").kind == .unchanged)
    }
}
