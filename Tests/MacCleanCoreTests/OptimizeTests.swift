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
        // read-only need-check probes are allowed; the task must never claim or
        // attempt a privileged/destructive operation
        let outcome = engine.run(task, dryRun: false, probes: idleProbes)
        #expect(outcome.kind != .applied)
        expectReadOnly(recorder.calls)
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

    @Test func lintTimeoutCountsAsSkippedNotDeleted() throws {
        // S3: a plutil timeout is not proof of corruption — keep the file
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let prefs = home + "/Library/Preferences"
        try touch(prefs + "/com.example.maybe.plist", Data("{".utf8))
        let engine = makeEngine(home: home) { e, _, _ in
            if e.hasSuffix("plutil") { return .init(status: 124, stdout: "", timedOut: true) }
            return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(.fixBrokenConfigs, dryRun: false, probes: idleProbes)
        #expect(outcome.kind != .applied)
        #expect(FileStat.exists(prefs + "/com.example.maybe.plist"))
    }

    @Test func sharedFileListLintTimeoutKeepsFile() throws {
        // S3: same timeout rule for the shared-file-list repair pass
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = home + "/Library/Application Support/com.apple.sharedfilelist"
        try touch(dir + "/com.apple.LSSharedFileList.ApplicationRecentServers.sfl2",
                  Data("{".utf8))
        let engine = makeEngine(home: home) { e, _, _ in
            if e.hasSuffix("plutil") { return .init(status: 124, stdout: "", timedOut: true) }
            return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(.sharedFileListRepair, dryRun: false, probes: idleProbes)
        #expect(outcome.kind != .applied)
        #expect(FileStat.exists(dir + "/com.apple.LSSharedFileList.ApplicationRecentServers.sfl2"))
    }

    @Test func spotlightOrphanKeepsRuleOnMdfindError() throws {
        // S2: orphan only on a clean empty result; mdfind timeout/error keeps the rule
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let export = String(decoding: try PropertyListSerialization.data(
            fromPropertyList: ["EnabledPreferenceRules": ["com.example.ghost"]],
            format: .xml, options: 0), as: UTF8.self)
        let engine = makeEngine(home: home) { e, a, _ in
            if e.hasSuffix("defaults"), a.first == "export" {
                return .init(status: 0, stdout: export, timedOut: false)
            }
            if e.hasSuffix("mdfind") { return .init(status: 124, stdout: "", timedOut: true) }
            return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(.spotlightOrphanRulesCleanup, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .unchanged)
    }

    @Test func sqliteBusyTimeoutAndSeparateVacuumResult() throws {
        // O2: every sqlite3 call sets .timeout; a VACUUM failure does not undo a good DELETE
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let db = home + "/Library/Application Support/Knowledge/knowledgeC.db"
        try mkdir((db as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: db, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: db))
        try handle.truncate(atOffset: 101 * 1024 * 1024)   // ≥100MB, sparse
        try handle.close()

        let recorder = Recorder()
        let engine = makeEngine(home: home) { e, a, _ in
            recorder.calls.append((e, a))
            if a.last == "VACUUM;" { return .init(status: 1, stdout: "", timedOut: false) }
            return .init(status: 0, stdout: "", timedOut: false)
        }
        let outcome = engine.run(.coreduetCleanup, dryRun: false, probes: idleProbes)
        #expect(outcome.kind == .applied)
        let sqlCalls = recorder.calls.filter { $0.0 == "/usr/bin/sqlite3" }.map(\.1)
        #expect(sqlCalls.allSatisfy { Array($0.prefix(2)) == ["-cmd", ".timeout 5000"] })
        #expect(sqlCalls.contains { $0.last == "VACUUM;" })
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
        let dbCalls = recorder.calls.compactMap { $0.1.dropFirst(2).first }
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

@Suite struct OptimizeDiagnosticsTests {
    @Test(arguments: [
        ("430:54.21", 25_854),   // mmm:ss.cc — fractional part must not flip the unit
        ("00:05.50", 5),
        ("1:02:03", 3_723),
        ("2-03:04:05", 183_845),
        ("0:59.99", 59),
    ])
    func parseClock(input: String, expected: Int) {
        #expect(OptimizeDiagnostics.parseClock(input) == expected)
    }

    @Test func runawayDetectionUsesBasenameAndFractionalTime() throws {
        // O1: `ps -Aco` basenames may contain spaces; `430:54.21` must read as ~7.2h not 430s
        let shell: OptimizeEngine.Runner = { _, a, _ in
            if a == ["-Aco", "pid=,time=,etime=,comm="] {
                return .init(status: 0, stdout:
                    "  100 50000:30.50 2-00:00:00 My App\n  200 43000:00.00 1-00:00:00 WindowServer\n",
                    timedOut: false)
            }
            return .init(status: 0, stdout: "", timedOut: false)
        }
        let findings = OptimizeDiagnostics.run(shell: shell)
        #expect(findings.contains { $0.contains("My App") })
        #expect(!findings.contains { $0.contains("WindowServer") })
    }
}

// MARK: - admin tasks: Mole read-only precondition checks

/// The 5 admin tasks may only run read-only probes — record every argv and
/// assert none of the destructive halves (flush/reset/rebuild/periodic) appear.
private func expectReadOnly(_ calls: [(String, [String])]) {
    for (exe, args) in calls {
        let argv = ([exe] + args).joined(separator: " ")
        #expect(!argv.contains("sudo"))
        #expect(!argv.contains("osascript"))
        #expect(!argv.contains("-flushcache"))
        #expect(!argv.contains("resetUserPermissions"))
        #expect(!(exe.hasSuffix("route") && args.contains("flush")))
        #expect(!exe.hasSuffix("arp"))
        #expect(!(exe.hasSuffix("mdutil") && args.contains("-E")))
        #expect(!exe.hasSuffix("periodic"))
        if exe == "/bin/sh" {
            let script = args.joined(separator: " ")
            #expect(!script.contains("flush") && !script.contains("sudo")
                    && !script.contains("periodic"))
        }
    }
}

private func adminShell(_ responses: [String: Shell.Result]) -> (Recorder, OptimizeEngine.Runner) {
    let recorder = Recorder()
    let runner: OptimizeEngine.Runner = { e, a, _ in
        recorder.calls.append((e, a))
        return responses[e + " " + a.joined(separator: " ")]
            ?? .init(status: 0, stdout: "", timedOut: false)
    }
    return (recorder, runner)
}

/// scutil clean + a utun default route = active full-tunnel VPN (Mole's route probe
/// is invoked via sh -c so stderr merges into stdout, matching Mole's 2>&1).
private let vpnActive: [String: Shell.Result] = [
    "/usr/sbin/scutil --nc list": .init(status: 0, stdout:
        "* (Connected)      ABCD-1 IKEv2 \"Corp VPN\"\n", timedOut: false),
    "/bin/sh -c /usr/sbin/route -n get default 2>&1": .init(status: 0, stdout:
        "   route to: default\ndestination: default\n    gateway: 10.0.0.1\n  interface: utun3\n", timedOut: false),
]
/// scutil clean + an en0 default route = no VPN.
private let vpnNone: [String: Shell.Result] = [
    "/usr/sbin/scutil --nc list": .init(status: 0, stdout:
        "  (Disconnected)   ABCD-1 IKEv2 \"VPN\"\n", timedOut: false),
    "/bin/sh -c /usr/sbin/route -n get default 2>&1": .init(status: 0, stdout:
        "   route to: default\ndestination: default\n    gateway: 192.168.0.1\n  interface: en0\n", timedOut: false),
]

@Suite struct AdminTaskTests {
    private func engine(_ runner: @escaping OptimizeEngine.Runner, home: String = "") throws -> OptimizeEngine {
        var e = makeEngine(home: try home.isEmpty ? makeTempDir() : home, shell: runner)
        e.routeBinary = "/usr/sbin/route"  // pin so fake-runner keys stay machine-independent
        return e
    }

    // network_optimization — VPN gate, then mDNSResponder label, then always needs root
    @Test func networkOptSkipsOnActiveVPN() throws {
        let (rec, runner) = adminShell(vpnActive)
        let o = try engine(runner).run(.networkOptimization, dryRun: false, probes: idleProbes)
        #expect(o.kind == .skipped)
        #expect(o.message.contains("VPN"))
        expectReadOnly(rec.calls)
    }

    @Test func networkOptFailsOnUnknownVPN() throws {
        let (rec, runner) = adminShell([
            "/usr/sbin/scutil --nc list": .init(status: 1, stdout: "", timedOut: false),
        ])
        let o = try engine(runner).run(.networkOptimization, dryRun: true, probes: idleProbes)
        #expect(o.kind == .failed)
        expectReadOnly(rec.calls)
    }

    @Test func networkOptAdminRequiredAfterChecks() throws {
        var r = vpnNone
        r["/usr/bin/plutil -extract Label raw -o - /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist"] =
            .init(status: 0, stdout: "com.apple.mDNSResponder\n", timedOut: false)
        let (rec, runner) = adminShell(r)
        let o = try engine(runner).run(.networkOptimization, dryRun: false, probes: idleProbes)
        #expect(o.kind == .unavailable)
        #expect(o.message.contains("관리자 권한 필요"))
        expectReadOnly(rec.calls)
    }

    @Test func networkOptFailsOnUnexpectedLabel() throws {
        var r = vpnNone
        r["/usr/bin/plutil -extract Label raw -o - /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist"] =
            .init(status: 0, stdout: "com.evil.responder\n", timedOut: false)
        let (rec, runner) = adminShell(r)
        let o = try engine(runner).run(.networkOptimization, dryRun: true, probes: idleProbes)
        #expect(o.kind == .failed)
        expectReadOnly(rec.calls)
    }

    // network_stack_optimize — VPN gate, then route/DNS health probes
    @Test func networkStackSkipsOnActiveVPN() throws {
        let (rec, runner) = adminShell(vpnActive)
        let o = try engine(runner).run(.networkStackOptimize, dryRun: false, probes: idleProbes)
        #expect(o.kind == .skipped)
        expectReadOnly(rec.calls)
    }

    @Test func networkStackUnchangedWhenHealthy() throws {
        var r = vpnNone
        r["/usr/sbin/route -n get default"] = .init(status: 0, stdout: "  interface: en0\n", timedOut: false)
        r["/usr/bin/dscacheutil -q host -a name example.com"] = .init(status: 0, stdout: "ip_address: 1.2.3.4\n", timedOut: false)
        let (rec, runner) = adminShell(r)
        let o = try engine(runner).run(.networkStackOptimize, dryRun: true, probes: idleProbes)
        #expect(o.kind == .unchanged)
        #expect(o.message.contains("필요 없음"))
        expectReadOnly(rec.calls)
    }

    @Test func networkStackAdminRequiredWhenRouteBroken() throws {
        var r = vpnNone
        r["/usr/sbin/route -n get default"] = .init(status: 1, stdout: "", timedOut: false)
        r["/usr/bin/dscacheutil -q host -a name example.com"] = .init(status: 0, stdout: "", timedOut: false)
        let (rec, runner) = adminShell(r)
        let o = try engine(runner).run(.networkStackOptimize, dryRun: false, probes: idleProbes)
        #expect(o.kind == .unavailable)
        #expect(o.message.contains("관리자 권한 필요"))
        expectReadOnly(rec.calls)
    }

    @Test func networkStackFailsOnTimeout() throws {
        var r = vpnNone
        r["/usr/sbin/route -n get default"] = .init(status: 124, stdout: "", timedOut: true)
        let (rec, runner) = adminShell(r)
        let o = try engine(runner).run(.networkStackOptimize, dryRun: true, probes: idleProbes)
        #expect(o.kind == .failed)
        expectReadOnly(rec.calls)
    }

    // disk_permissions_repair — stat/access are direct syscalls, no commands at all
    @Test func diskPermsUnchangedWhenHealthy() throws {
        let home = try makeTempDir()
        try mkdir(home + "/Library/Preferences")
        let (rec, runner) = adminShell([:])
        let o = makeEngine(home: home, shell: runner)
            .run(.diskPermissionsRepair, dryRun: false, probes: idleProbes)
        #expect(o.kind == .unchanged)
        #expect(o.message.contains("필요 없음"))
        #expect(rec.calls.isEmpty)
    }

    @Test func diskPermsAdminRequiredWhenUnwritable() throws {
        let home = try makeTempDir()
        try mkdir(home + "/Library/Preferences")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home) }
        let (rec, runner) = adminShell([:])
        let o = makeEngine(home: home, shell: runner)
            .run(.diskPermissionsRepair, dryRun: true, probes: idleProbes)
        #expect(o.kind == .unavailable)
        #expect(o.message.contains("관리자 권한 필요"))
        expectReadOnly(rec.calls)
    }

    // spotlight_index_optimize — mdutil state, battery gate, two timed mdfind probes
    @Test func spotlightSkippedWhenIndexingDisabled() throws {
        let (rec, runner) = adminShell([
            "/usr/bin/mdutil -s /": .init(status: 0, stdout: "/:\n\tIndexing disabled.\n", timedOut: false),
        ])
        let o = try engine(runner).run(.spotlightIndexOptimize, dryRun: false, probes: idleProbes)
        #expect(o.kind == .skipped)
        expectReadOnly(rec.calls)
    }

    @Test func spotlightSkippedOnBattery() throws {
        let (rec, runner) = adminShell([
            "/usr/bin/mdutil -s /": .init(status: 0, stdout: "/:\n\tIndexing enabled.\n", timedOut: false),
            "/usr/bin/pmset -g batt": .init(status: 0, stdout: "Now drawing from 'Battery Power'\n", timedOut: false),
        ])
        let o = try engine(runner).run(.spotlightIndexOptimize, dryRun: true, probes: idleProbes)
        #expect(o.kind == .skipped)
        expectReadOnly(rec.calls)
    }

    @Test func spotlightUnchangedWhenProbesFast() throws {
        let (rec, runner) = adminShell([
            "/usr/bin/mdutil -s /": .init(status: 0, stdout: "/:\n\tIndexing enabled.\n", timedOut: false),
            "/usr/bin/pmset -g batt": .init(status: 0, stdout: "Now drawing from 'AC Power'\n", timedOut: false),
        ])
        let o = try engine(runner).run(.spotlightIndexOptimize, dryRun: false, probes: idleProbes)
        #expect(o.kind == .unchanged)
        #expect(o.message.contains("필요 없음"))
        expectReadOnly(rec.calls)
    }

    @Test func spotlightAdminRequiredWhenBothProbesTimeout() throws {
        let (rec, runner) = adminShell([
            "/usr/bin/mdutil -s /": .init(status: 0, stdout: "/:\n\tIndexing enabled.\n", timedOut: false),
            "/usr/bin/pmset -g batt": .init(status: 0, stdout: "Now drawing from 'AC Power'\n", timedOut: false),
            "/usr/bin/mdfind kMDItemFSName == 'Applications'": .init(status: 124, stdout: "", timedOut: true),
        ])
        let o = try engine(runner).run(.spotlightIndexOptimize, dryRun: true, probes: idleProbes)
        #expect(o.kind == .unavailable)
        #expect(o.message.contains("관리자 권한 필요"))
        expectReadOnly(rec.calls)
    }

    @Test func spotlightAdminRequiredWhenProbesSlow() throws {
        let (rec, runner) = adminShell([
            "/usr/bin/mdutil -s /": .init(status: 0, stdout: "/:\n\tIndexing enabled.\n", timedOut: false),
            "/usr/bin/pmset -g batt": .init(status: 0, stdout: "Now drawing from 'AC Power'\n", timedOut: false),
        ])
        var e = try engine(runner)
        e.spotlightSlowThreshold = 0  // any measurable duration counts as slow
        let o = e.run(.spotlightIndexOptimize, dryRun: false, probes: idleProbes)
        #expect(o.kind == .unavailable)
        expectReadOnly(rec.calls)
    }

    @Test func spotlightFailsWhenProbeErrors() throws {
        let (rec, runner) = adminShell([
            "/usr/bin/mdutil -s /": .init(status: 0, stdout: "/:\n\tIndexing enabled.\n", timedOut: false),
            "/usr/bin/pmset -g batt": .init(status: 0, stdout: "Now drawing from 'AC Power'\n", timedOut: false),
            "/usr/bin/mdfind kMDItemFSName == 'Applications'": .init(status: 1, stdout: "", timedOut: false),
        ])
        let o = try engine(runner).run(.spotlightIndexOptimize, dryRun: true, probes: idleProbes)
        #expect(o.kind == .failed)
        expectReadOnly(rec.calls)
    }

    @Test func spotlightFailsWhenMdutilErrors() throws {
        let (rec, runner) = adminShell([
            "/usr/bin/mdutil -s /": .init(status: 1, stdout: "", timedOut: false),
        ])
        let o = try engine(runner).run(.spotlightIndexOptimize, dryRun: false, probes: idleProbes)
        #expect(o.kind == .failed)
        expectReadOnly(rec.calls)
    }

    // periodic_maintenance — tool existence + daily.out mtime (direct file checks)
    @Test func periodicUnsupportedWhenToolMissing() throws {
        var e = try engine { _, _, _ in .init(status: 0, stdout: "", timedOut: false) }
        e.periodicBinary = "/nonexistent/periodic"
        let o = e.run(.periodicMaintenance, dryRun: false, probes: idleProbes)
        #expect(o.kind == .unavailable)
        #expect(o.message.contains("이 macOS에서 지원 안 함"))
    }

    @Test func periodicUnchangedWhenLogFresh() throws {
        let home = try makeTempDir()
        try touch(home + "/daily.out")
        var e = try engine({ _, _, _ in .init(status: 0, stdout: "", timedOut: false) }, home: home)
        e.periodicBinary = "/bin/sh"  // any existing file stands in for the tool
        e.periodicLog = home + "/daily.out"
        let o = e.run(.periodicMaintenance, dryRun: true, probes: idleProbes)
        #expect(o.kind == .unchanged)
        #expect(o.message.contains("필요 없음"))
    }

    @Test func periodicAdminRequiredWhenLogStale() throws {
        let home = try makeTempDir()
        try touch(home + "/daily.out")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: home + "/daily.out")
        var e = try engine({ _, _, _ in .init(status: 0, stdout: "", timedOut: false) }, home: home)
        e.periodicBinary = "/bin/sh"
        e.periodicLog = home + "/daily.out"
        let o = e.run(.periodicMaintenance, dryRun: false, probes: idleProbes)
        #expect(o.kind == .unavailable)
        #expect(o.message.contains("관리자 권한 필요"))
    }

    @Test func periodicAdminRequiredWhenLogMissing() throws {
        let home = try makeTempDir()
        var e = try engine({ _, _, _ in .init(status: 0, stdout: "", timedOut: false) }, home: home)
        e.periodicBinary = "/bin/sh"
        e.periodicLog = home + "/daily.out"
        let o = e.run(.periodicMaintenance, dryRun: true, probes: idleProbes)
        #expect(o.kind == .unavailable)
        #expect(o.message.contains("관리자 권한 필요"))
    }
}
