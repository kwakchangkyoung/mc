import Darwin
import Foundation

/// Executes Mole's optimize tasks at user level. Every file removal goes through SafeDeleter;
/// external commands run through a fixed-argv runner with a timeout (DESIGN principle 4).
/// Tasks that need admin rights are refused with `.unavailable` — the M6 privileged helper
/// will own them later, and the app never runs as root (DESIGN principle 5).
public struct OptimizeEngine: Sendable {
    public typealias Runner = @Sendable (String, [String], TimeInterval) -> Shell.Result

    public let home: String
    public let deleter: SafeDeleter
    public let whitelist: OptimizeWhitelist
    public let shell: Runner

    public init(home: String, deleter: SafeDeleter, whitelist: OptimizeWhitelist,
                shell: @escaping Runner = { Shell.run($0, $1, timeout: $2) }) {
        self.home = home
        self.deleter = deleter
        self.whitelist = whitelist
        self.shell = shell
    }

    private var lib: String { home + "/Library" }

    // MARK: dispatch

    public func run(_ task: OptimizeTask, dryRun: Bool = false, probes: ProbeContext) -> OptimizeOutcome {
        if whitelist.contains(task) {
            return OptimizeOutcome(task, .skipped, "화이트리스트에 등록됨")
        }
        switch task {
        case .cacheRefresh: return cacheRefresh(dryRun: dryRun, probes: probes)
        case .savedStateCleanup: return savedStateCleanup(dryRun: dryRun, probes: probes)
        case .fixBrokenConfigs: return fixBrokenConfigs(dryRun: dryRun, probes: probes)
        case .sqliteVacuum: return sqliteVacuum(dryRun: dryRun, probes: probes)
        case .preventNetworkDsstore: return preventNetworkDsstore(dryRun: dryRun)
        case .legacyOverridesAudit: return legacyOverridesAudit(dryRun: dryRun)
        case .spotlightOrphanRulesCleanup: return spotlightOrphanRules(dryRun: dryRun)
        case .sharedFileListRepair: return sharedFileListRepair(dryRun: dryRun, probes: probes)
        case .diskVerify: return diskVerify(dryRun: dryRun)
        case .loginItemsAudit: return loginItemsAudit()
        case .quarantineCleanup: return quarantineCleanup(dryRun: dryRun)
        case .launchAgentsCleanup: return launchAgentsCleanup()
        case .notificationCleanup: return notificationCleanup(dryRun: dryRun)
        case .coreduetCleanup: return coreduetCleanup(dryRun: dryRun)
        case .networkOptimization: return networkOptimization()
        case .networkStackOptimize: return networkStackOptimize()
        case .diskPermissionsRepair: return diskPermissionsRepair()
        case .spotlightIndexOptimize: return spotlightIndexOptimize()
        case .periodicMaintenance: return periodicMaintenance()
        }
    }

    // MARK: helpers

    private func children(_ dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    }

    private func removeOne(_ path: String, dryRun: Bool, probes: ProbeContext,
                           removed: inout Int, failed: inout Int, skipped: inout Int,
                           bytes: inout Int64) {
        switch deleter.remove(path, expected: PathIdentity.capture(path), dryRun: dryRun,
                              probes: probes, command: dryRun ? "optimize-dry-run" : "optimize") {
        case .removed(let s), .wouldRemove(let s):
            removed += 1
            bytes += s.bytes
        case .failed: failed += 1
        case .skipped: skipped += 1
        case .missing: break
        }
    }

    private func sqlite3(_ path: String, _ sql: String, _ timeout: TimeInterval) -> Shell.Result {
        shell("/usr/bin/sqlite3", ["-cmd", ".timeout 5000", path, sql], timeout)
    }

    private var hasSQLite3: Bool { FileStat.exists("/usr/bin/sqlite3") }

    private func isSQLiteFile(_ path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let data = try? handle.read(upToCount: 16) else { return false }
        try? handle.close()
        return data.count == 16 && data.starts(with: Array("SQLite format 3\0".utf8))
    }

    private func darwinUserDir() -> String? {
        DarwinDirs.userDir()
    }

    private func fileSize(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        return st.st_size
    }

    // MARK: 1. cache_refresh (tasks.sh:209)

    private func cacheRefresh(dryRun: Bool, probes: ProbeContext) -> OptimizeOutcome {
        let dirs = [lib + "/Caches/com.apple.QuickLook.thumbnailcache",
                    lib + "/Caches/com.apple.iconservices.store",
                    lib + "/Caches/com.apple.iconservices"]
        if !dryRun {
            _ = shell("/usr/bin/qlmanage", ["-r", "cache"], 15)
            _ = shell("/usr/bin/qlmanage", ["-r"], 15)
        }
        var removed = 0, failed = 0, skipped = 0
        var bytes: Int64 = 0
        for dir in dirs where FileStat.exists(dir) {
            removeOne(dir, dryRun: dryRun, probes: probes,
                      removed: &removed, failed: &failed, skipped: &skipped, bytes: &bytes)
        }
        let dry = dryRun ? "예정" : ""
        return .fromCounts(.cacheRefresh, applied: removed, failed: failed, skipped: skipped,
                           message: "캐시 \(removed)개 정리\(dry), \(ByteFormat.string(bytes))")
    }

    // MARK: 2. saved_state_cleanup (tasks.sh:316)

    private func savedStateCleanup(dryRun: Bool, probes: ProbeContext) -> OptimizeOutcome {
        let dir = lib + "/Saved Application State"
        guard FileStat.isDirectory(dir) else {
            return OptimizeOutcome(.savedStateCleanup, .unchanged, "저장 상태 디렉터리 없음")
        }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var removed = 0, failed = 0, skipped = 0
        var bytes: Int64 = 0
        for name in children(dir) where name.hasSuffix(".savedState") {
            let path = dir + "/" + name
            guard let mtime = FileStat.modificationDate(path), mtime < cutoff else { continue }
            removeOne(path, dryRun: dryRun, probes: probes,
                      removed: &removed, failed: &failed, skipped: &skipped, bytes: &bytes)
        }
        let dry = dryRun ? " 예정" : ""
        return .fromCounts(.savedStateCleanup, applied: removed, failed: failed, skipped: skipped,
                           message: "\(removed)개 오래된 저장 상태 삭제\(dry), \(ByteFormat.string(bytes))")
    }

    // MARK: 3. fix_broken_configs (tasks.sh:381, maintenance.sh:7)

    private func fixBrokenConfigs(dryRun: Bool, probes: ProbeContext) -> OptimizeOutcome {
        let deadline = Date().addingTimeInterval(15)
        var removed = 0, failed = 0, skipped = 0
        var bytes: Int64 = 0
        for dir in [lib + "/Preferences", lib + "/Preferences/ByHost"] {
            let isTop = dir.hasSuffix("/Preferences")
            for name in children(dir) where name.hasSuffix(".plist") {
                if Date() > deadline {
                    return OptimizeOutcome(.fixBrokenConfigs, .failed,
                                           "검사 시간 초과 — 부분 처리됨(\(removed)개 삭제)")
                }
                // Apple·글로벌 설정과 로그인윈도우는 건드리지 않음
                if name.hasPrefix("com.apple.") || name.hasPrefix(".GlobalPreferences") { continue }
                if isTop && name == "loginwindow.plist" { continue }
                let path = dir + "/" + name
                guard FileManager.default.isReadableFile(atPath: path) else {
                    skipped += 1   // 읽기 불가 파일은 유지
                    continue
                }
                // 반드시 /usr/bin/plutil (PATH shim 방지)
                let lint = shell("/usr/bin/plutil", ["-lint", path], 10)
                if lint.timedOut {
                    skipped += 1   // 타임아웃은 손상 증거가 아님 — 유지
                } else if lint.status != 0 {
                    removeOne(path, dryRun: dryRun, probes: probes,
                              removed: &removed, failed: &failed, skipped: &skipped, bytes: &bytes)
                }
            }
        }
        let dry = dryRun ? " 예정" : ""
        return .fromCounts(.fixBrokenConfigs, applied: removed, failed: failed, skipped: skipped,
                           message: "\(removed)개 손상된 설정 삭제\(dry)")
    }

    // MARK: 5. sqlite_vacuum (tasks.sh:528)

    private func sqliteVacuum(dryRun: Bool, probes: ProbeContext) -> OptimizeOutcome {
        switch probes.processes.state(names: ["Mail", "Safari", "Messages"]) {
        case .running:
            return OptimizeOutcome(.sqliteVacuum, .skipped,
                                   "Mail·Safari·메시지 실행 중 — 앱 종료 후 다시 실행")
        case .unknown:
            return OptimizeOutcome(.sqliteVacuum, .skipped, "앱 실행 상태 확인 불가")
        case .notRunning:
            break
        }
        guard hasSQLite3 else {
            return OptimizeOutcome(.sqliteVacuum, .unavailable, "sqlite3 없음")
        }

        var dbs: [String] = []
        for path in CleanEngine.expand(lib + "/Mail/V*/MailData/Envelope Index*")
        where !path.hasSuffix("-wal") && !path.hasSuffix("-shm") { dbs.append(path) }
        for path in [lib + "/Messages/chat.db", lib + "/Safari/History.db",
                     lib + "/Safari/TopSites.db"] where FileStat.exists(path) { dbs.append(path) }

        var vacuumed = 0, failed = 0, policySkipped = 0, optimal = 0
        for db in dbs {
            // Mole: should_protect_path → 조용히 건너뜀 (tasks.sh:621)
            if deleter.policy.protection.shouldProtectPath(db) { continue }
            guard FileManager.default.isReadableFile(atPath: db), isSQLiteFile(db) else { continue }
            if fileSize(db) > 104_857_600 {        // MOLE_SQLITE_MAX_SIZE = 100MB
                policySkipped += 1
                continue
            }
            let counts = sqlite3(db, "PRAGMA page_count; PRAGMA freelist_count;", 5)
            let ints = counts.stdout.split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if counts.status != 0 || ints.count < 2 {
                failed += 1
                continue
            }
            if ints[0] > 0 && Double(ints[1]) / Double(ints[0]) < 0.05 {
                optimal += 1          // freelist < 5% → already optimal
                continue
            }
            let integrity = sqlite3(db, "PRAGMA integrity_check;", 10)
            guard integrity.status == 0,
                  integrity.stdout.split(whereSeparator: \.isNewline).first == "ok" else {
                failed += 1
                continue
            }
            if dryRun {
                vacuumed += 1
                continue
            }
            let vacuum = sqlite3(db, "VACUUM;", 20)
            if vacuum.status == 0 && !vacuum.timedOut { vacuumed += 1 } else { failed += 1 }
        }
        if dbs.isEmpty {
            return OptimizeOutcome(.sqliteVacuum, .unchanged, "대상 데이터베이스 없음")
        }
        var message = "\(vacuumed)개 데이터베이스 최적화" + (dryRun ? " 예정" : "")
        if optimal > 0 { message += ", \(optimal)개 이미 최적" }
        if policySkipped > 0 { message += ", \(policySkipped)개 대용량 건너뜀" }
        return .fromCounts(.sqliteVacuum, applied: vacuumed, failed: failed,
                           skipped: policySkipped, message: message)
    }

    // MARK: 6. prevent_network_dsstore (tasks.sh:1096)

    private func preventNetworkDsstore(dryRun: Bool) -> OptimizeOutcome {
        guard let suite = UserDefaults(suiteName: "com.apple.desktopservices") else {
            return OptimizeOutcome(.preventNetworkDsstore, .unavailable, "설정 도메인 접근 불가")
        }
        var changed = 0
        for key in ["DSDontWriteNetworkStores", "DSDontWriteUSBStores"] {
            if (suite.object(forKey: key) as? Bool) == true { continue }
            if !dryRun { suite.set(true, forKey: key) }
            changed += 1
        }
        if changed == 0 {
            return OptimizeOutcome(.preventNetworkDsstore, .unchanged, "이미 설정되어 있음")
        }
        return OptimizeOutcome(.preventNetworkDsstore, .applied,
                               "\(changed)개 설정 적용" + (dryRun ? " 예정" : "")
                               + " (Finder 재시작 후 반영)")
    }

    // MARK: 7. legacy_overrides_audit (tasks.sh:1145)

    private func legacyOverridesAudit(dryRun: Bool) -> OptimizeOutcome {
        // 값이 1/true/yes 일 때만 대상
        func isTruthy(_ r: Shell.Result) -> Bool {
            guard r.status == 0 else { return false }
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes"].contains(v)
        }
        var targets: [(domain: String, key: String)] = []
        let whitelist = deleter.whitelist
        if !whitelist.contains(lib + "/Preferences/.GlobalPreferences.plist"),
           isTruthy(shell("/usr/bin/defaults", ["read", "-g", "NSAppSleepDisabled"], 3)) {
            targets.append(("-g", "NSAppSleepDisabled"))
        }
        if !whitelist.contains(lib + "/Preferences/com.apple.frameworks.diskimages.plist") {
            for key in ["skip-verify", "skip-verify-locked", "skip-verify-remote"]
            where isTruthy(shell("/usr/bin/defaults",
                                 ["read", "com.apple.frameworks.diskimages", key], 3)) {
                targets.append(("com.apple.frameworks.diskimages", key))
            }
        }
        guard !targets.isEmpty else {
            return OptimizeOutcome(.legacyOverridesAudit, .unchanged, "오버라이드 없음")
        }
        var applied = 0, failed = 0
        for t in targets where !dryRun {
            let r = shell("/usr/bin/defaults", ["delete", t.domain, t.key], 5)
            if r.status == 0 { applied += 1 } else { failed += 1 }
        }
        if dryRun { applied = targets.count }
        return .fromCounts(.legacyOverridesAudit, applied: applied, failed: failed, skipped: 0,
                           message: "\(applied)개 오버라이드 제거" + (dryRun ? " 예정" : ""))
    }

    // MARK: 11. spotlight_orphan_rules_cleanup (tasks.sh:984)

    private func spotlightOrphanRules(dryRun: Bool) -> OptimizeOutcome {
        // cfprefsd를 거치는 읽기: defaults export → bplist
        func export() -> [String: Any]? {
            let r = shell("/usr/bin/defaults", ["export", "com.apple.spotlight", "-"], 5)
            guard r.status == 0, let data = r.stdout.data(using: .utf8),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any] else { return nil }
            return obj
        }
        guard let snapshot = export(),
              let rules = snapshot["EnabledPreferenceRules"] as? [String], !rules.isEmpty else {
            return OptimizeOutcome(.spotlightOrphanRulesCleanup, .unchanged, "Spotlight 규칙 없음")
        }
        // 유지 조건: System.*/com.apple.*/역DNS 아님/첫 라벨이 소문자·숫자가 아님
        let candidates = rules.filter { rule in
            if rule.hasPrefix("System.") || rule.hasPrefix("com.apple.") { return false }
            guard LeftoverFinder.isReverseDNS(rule),
                  let first = rule.first, first.isLowercase || first.isNumber else { return false }
            return true
        }
        guard !candidates.isEmpty else {
            return OptimizeOutcome(.spotlightOrphanRulesCleanup, .unchanged, "검사 대상 규칙 없음")
        }
        // 앱 존재 확인: Spotlight 검색 + 설치 앱 목록 (보수적으로 설치된 것으로 간주)
        let installed = Set(AppInventory(home: home)
            .discover(protection: deleter.policy.protection).map { $0.bundleID })
        var orphans: [String] = []
        var kept = rules
        for rule in candidates {
            // orphan only on a clean "no results": a mdfind timeout/error keeps the rule
            let r = shell("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(rule)'"], 5)
            let found = installed.contains(rule) || r.timedOut || r.status != 0
                || !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if found { continue }
            orphans.append(rule)
            kept.removeAll { $0 == rule }
        }
        guard !orphans.isEmpty else {
            return OptimizeOutcome(.spotlightOrphanRulesCleanup, .unchanged, "고아 규칙 없음")
        }
        if dryRun {
            return OptimizeOutcome(.spotlightOrphanRulesCleanup, .applied,
                                   "\(orphans.count)개 고아 규칙 제거 예정", detail: orphans)
        }
        // 쓰기 직전 스냅샷 재비교 — 외부 변경 감지 시 중단
        guard let now = export(),
              (now["EnabledPreferenceRules"] as? [String] ?? []) == rules else {
            return OptimizeOutcome(.spotlightOrphanRulesCleanup, .failed, "규칙이 변경됨 — 중단")
        }
        let r: Shell.Result
        if kept.isEmpty {
            r = shell("/usr/bin/defaults", ["delete", "com.apple.spotlight", "EnabledPreferenceRules"], 5)
        } else {
            r = shell("/usr/bin/defaults",
                      ["write", "com.apple.spotlight", "EnabledPreferenceRules", "-array"] + kept, 5)
        }
        if r.status != 0 {
            return OptimizeOutcome(.spotlightOrphanRulesCleanup, .failed, "규칙 쓰기 실패")
        }
        return OptimizeOutcome(.spotlightOrphanRulesCleanup, .applied,
                               "\(orphans.count)개 고아 규칙 제거", detail: orphans)
    }

    // MARK: 13. shared_file_list_repair (tasks.sh:1345)

    private func sharedFileListRepair(dryRun: Bool, probes: ProbeContext) -> OptimizeOutcome {
        let dir = lib + "/Application Support/com.apple.sharedfilelist"
        guard FileStat.isDirectory(dir) else {
            return OptimizeOutcome(.sharedFileListRepair, .unchanged, "디렉터리 없음")
        }
        guard let enumerator = FileManager.default.enumerator(atPath: dir) else {
            return OptimizeOutcome(.sharedFileListRepair, .unavailable,
                                   "디렉터리 접근 불가 — 전체 디스크 접근 권한 확인")
        }
        var removed = 0, failed = 0, skipped = 0
        var bytes: Int64 = 0
        while let name = enumerator.nextObject() as? String {
            guard ["sfl2", "sfl3", "sfl4"].contains((name as NSString).pathExtension),
                  !name.contains("ApplicationRecentDocuments") else { continue }
            let path = dir + "/" + name
            let lint = shell("/usr/bin/plutil", ["-lint", path], 10)
            if lint.timedOut {
                skipped += 1   // 타임아웃은 손상 증거가 아님 — 유지
            } else if lint.status != 0 {
                removeOne(path, dryRun: dryRun, probes: probes,
                          removed: &removed, failed: &failed, skipped: &skipped, bytes: &bytes)
            }
        }
        let dry = dryRun ? " 예정" : ""
        return .fromCounts(.sharedFileListRepair, applied: removed, failed: failed, skipped: skipped,
                           message: "\(removed)개 손상된 파일 목록 삭제\(dry)")
    }

    // MARK: 14. disk_verify (tasks.sh:1502) — 기본 비활성

    private func diskVerify(dryRun: Bool) -> OptimizeOutcome {
        guard ProcessInfo.processInfo.environment["MACCLEAN_ENABLE_DISK_VERIFY"] == "1" else {
            return OptimizeOutcome(.diskVerify, .skipped,
                                   "기본 비활성화됨 (MACCLEAN_ENABLE_DISK_VERIFY=1)")
        }
        if dryRun { return OptimizeOutcome(.diskVerify, .skipped, "dry-run에서는 실행하지 않음") }
        let r = shell("/usr/sbin/diskutil", ["verifyVolume", "/"], 30)
        if r.timedOut { return OptimizeOutcome(.diskVerify, .failed, "검증 시간 초과") }
        if r.stdout.contains("appears to be OK") {
            return OptimizeOutcome(.diskVerify, .unchanged, "파일시스템 정상")
        }
        if r.stdout.range(of: "error|corrupt|invalid", options: [.regularExpression, .caseInsensitive]) != nil {
            return OptimizeOutcome(.diskVerify, .attention,
                                   "디스크 오류 가능성 — sudo diskutil repairVolume / 실행 권장")
        }
        return OptimizeOutcome(.diskVerify, .failed, "검증 실패")
    }

    // MARK: 15. login_items_audit (tasks.sh:1618) — 보고만

    private func loginItemsAudit() -> OptimizeOutcome {
        let deadline = Date().addingTimeInterval(15)
        let r = shell("/usr/bin/osascript",
                      ["-e", "tell application \"System Events\" to get the name of every login item"], 5)
        guard r.status == 0 else {
            return OptimizeOutcome(.loginItemsAudit, .unavailable,
                                   "System Events 접근 불가 — 자동화 권한 필요")
        }
        let names = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ", ").filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return OptimizeOutcome(.loginItemsAudit, .unchanged, "로그인 항목 없음")
        }
        // Mole checks the item's POSIX path first — existing target means not broken.
        // A list fetch fails entirely when any item has no path, so query per item.
        func itemPath(_ name: String) -> String? {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let r = shell("/usr/bin/osascript", ["-e",
                "tell application \"System Events\" to get path of login item \"\(escaped)\""], 5)
            guard r.status == 0 else { return nil }
            let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? nil : p
        }
        let installedNames = Set(AppInventory(home: home)
            .scan(protection: deleter.policy.protection).flatMap {
                [$0.name, LeftoverFinder.baseName($0.name)]
            })
        var broken: [String] = []
        for name in names {
            if Date() > deadline {
                return OptimizeOutcome(.loginItemsAudit, .unavailable, "검사 시간 초과")
            }
            if let path = itemPath(name), FileStat.exists(path) { continue }
            let trimmed = Self.stripHelperSuffix(name)
            let found = installedNames.contains(name) || installedNames.contains(trimmed) || {
                let r = shell("/usr/bin/mdfind", ["kMDItemFSName == '\(trimmed).app'"], 5)
                return r.status == 0 && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }()
            if !found { broken.append(name) }
        }
        if broken.isEmpty {
            return OptimizeOutcome(.loginItemsAudit, .unchanged, "깨진 로그인 항목 없음")
        }
        return OptimizeOutcome(.loginItemsAudit, .attention,
                               "\(broken.count)개 깨진 로그인 항목 — 시스템 설정 > 일반 > 로그인 항목에서 제거",
                               detail: broken)
    }

    /// Mole이 시도하는 이름 변형: Client|Helper|Agent|Launcher|Service 접미사 제거.
    static func stripHelperSuffix(_ name: String) -> String {
        for suffix in ["Client", "Helper", "Agent", "Launcher", "Service"]
        where name.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    // MARK: 16. quarantine_cleanup (tasks.sh:465)

    private func quarantineCleanup(dryRun: Bool) -> OptimizeOutcome {
        let db = lib + "/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        guard FileStat.exists(db) else {
            return OptimizeOutcome(.quarantineCleanup, .unchanged, "격리 데이터베이스 없음")
        }
        // Mole: should_protect_path → unchanged (파일명이 com.apple.*라 사실상 항상 보호됨)
        guard !deleter.policy.protection.shouldProtectPath(db) else {
            return OptimizeOutcome(.quarantineCleanup, .unchanged, "격리 데이터베이스 보호됨")
        }
        guard hasSQLite3 else {
            return OptimizeOutcome(.quarantineCleanup, .unavailable, "sqlite3 없음")
        }
        let count = sqlite3(db, "SELECT COUNT(*) FROM LSQuarantineEvent;", 5)
        guard count.status == 0,
              let n = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 else {
            return OptimizeOutcome(.quarantineCleanup, .unchanged, "삭제할 다운로드 이력 없음")
        }
        if dryRun {
            return OptimizeOutcome(.quarantineCleanup, .applied, "\(n)개 다운로드 이력 삭제 예정")
        }
        let r = sqlite3(db, "DELETE FROM LSQuarantineEvent;", 10)
        if r.status != 0 || r.timedOut {
            return OptimizeOutcome(.quarantineCleanup, .failed, "데이터베이스 잠김 또는 오류")
        }
        // DELETE 성공은 VACUUM 실패와 별개로 보고한다
        let vacuum = sqlite3(db, "VACUUM;", 10)
        let note = vacuum.status == 0 && !vacuum.timedOut ? "" : " (VACUUM 실패)"
        return OptimizeOutcome(.quarantineCleanup, .applied, "\(n)개 다운로드 이력 삭제" + note)
    }

    // MARK: 17. launch_agents_cleanup (tasks.sh:1215) — 보고만

    private func launchAgentsCleanup() -> OptimizeOutcome {
        let dir = lib + "/LaunchAgents"
        guard FileStat.isDirectory(dir) else {
            return OptimizeOutcome(.launchAgentsCleanup, .unchanged, "LaunchAgents 디렉터리 없음")
        }
        let mounted = Set(children("/Volumes"))
        var broken: [String] = []
        for name in children(dir) where name.hasSuffix(".plist") {
            let path = dir + "/" + name
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any] else { continue }
            var program = obj["Program"] as? String
            if program == nil, let args = obj["ProgramArguments"] as? [Any] {
                program = args.first as? String
            }
            guard let p = program, p.hasPrefix("/"), !FileStat.exists(p) else { continue }
            // 미마운트 /Volumes/<disk> 대상은 깨진 것으로 보지 않음
            if p.hasPrefix("/Volumes/") {
                let vol = p.split(separator: "/").dropFirst(1).first.map(String.init)
                if let vol, !mounted.contains(vol) { continue }
            }
            broken.append(name)
        }
        if broken.isEmpty {
            return OptimizeOutcome(.launchAgentsCleanup, .unchanged, "깨진 LaunchAgent 없음")
        }
        return OptimizeOutcome(.launchAgentsCleanup, .attention,
                               "\(broken.count)개 LaunchAgent가 사라진 프로그램을 가리킴 — 수동 정리 권장",
                               detail: broken)
    }

    // MARK: 18. notification_cleanup (tasks.sh:1429)

    private func notificationCleanup(dryRun: Bool) -> OptimizeOutcome {
        var candidates = [lib + "/Group Containers/group.com.apple.usernoted/db2/db"]
        if let userDir = darwinUserDir() {
            candidates.append(userDir + "com.apple.notificationcenter/db2/db")
        }
        guard let db = candidates.first(where: FileStat.exists) else {
            return OptimizeOutcome(.notificationCleanup, .unavailable, "알림 데이터베이스 없음")
        }
        // 50MB 미만이면 정리할 가치 없음
        guard fileSize(db) >= 50 * 1024 * 1024 else {
            return OptimizeOutcome(.notificationCleanup, .unchanged,
                                   "알림 DB가 작음 (\(ByteFormat.string(fileSize(db))))")
        }
        guard hasSQLite3 else {
            return OptimizeOutcome(.notificationCleanup, .unavailable, "sqlite3 없음")
        }
        if dryRun {
            return OptimizeOutcome(.notificationCleanup, .applied, "알림 기록 정리 예정")
        }
        // delivered_date는 Mac epoch(2001-01-01) — 실측으로 확인(Unix epoch 비교는 Mole의 버그로
        // 전 행을 삭제하게 됨). coreduet과 같은 방식으로 오프셋을 뺀다.
        let r = sqlite3(db,
                        "DELETE FROM record WHERE delivered_date < "
                            + "(strftime('%s','now','-30 days') - strftime('%s','2001-01-01'));",
                        10)
        if r.status != 0 || r.timedOut {
            return OptimizeOutcome(.notificationCleanup, .failed, "데이터베이스 잠김 또는 오류")
        }
        // DELETE 성공은 VACUUM 실패와 별개로 보고한다
        let vacuum = sqlite3(db, "VACUUM;", 10)
        let note = vacuum.status == 0 && !vacuum.timedOut ? "" : " (VACUUM 실패)"
        // NotificationCenter 재시작 — 실패해도 무시 (launchctl kill, PID kill 금지)
        _ = shell("/bin/launchctl",
                  ["kill", "SIGTERM", "gui/\(getuid())/com.apple.notificationcenterui.agent"], 5)
        return OptimizeOutcome(.notificationCleanup, .applied, "알림 기록 정리" + note)
    }

    // MARK: 19. coreduet_cleanup (tasks.sh:1544)

    private func coreduetCleanup(dryRun: Bool) -> OptimizeOutcome {
        let db = lib + "/Application Support/Knowledge/knowledgeC.db"
        guard FileStat.exists(db) else {
            return OptimizeOutcome(.coreduetCleanup, .unchanged, "Knowledge 데이터베이스 없음")
        }
        // WAL/SHM을 먼저 지우지 않는다 — 합계 크기만 측정
        let total = [db, db + "-wal", db + "-shm"].map(fileSize).reduce(0, +)
        guard total >= 100 * 1024 * 1024 else {
            return OptimizeOutcome(.coreduetCleanup, .unchanged,
                                   "사용 기록 DB가 작음 (\(ByteFormat.string(total)))")
        }
        guard hasSQLite3 else {
            return OptimizeOutcome(.coreduetCleanup, .unavailable, "sqlite3 없음")
        }
        if dryRun {
            return OptimizeOutcome(.coreduetCleanup, .applied, "90일 지난 사용 기록 삭제 예정")
        }
        let sql = "DELETE FROM ZOBJECT WHERE ZCREATIONDATE < "
            + "(strftime('%s','now','-90 days') - strftime('%s','2001-01-01'));"
        let r = sqlite3(db, sql, 20)
        if r.status != 0 || r.timedOut {
            return OptimizeOutcome(.coreduetCleanup, .failed, "데이터베이스 잠김 또는 오류")
        }
        // DELETE 성공은 VACUUM 실패와 별개로 보고한다
        let vacuum = sqlite3(db, "VACUUM;", 20)
        let note = vacuum.status == 0 && !vacuum.timedOut ? "" : " (VACUUM 실패)"
        return OptimizeOutcome(.coreduetCleanup, .applied, "90일 지난 사용 기록 삭제" + note)
    }

    // MARK: admin tasks — Mole's read-only precondition checks
    //
    // The destructive half of these tasks (dscacheutil -flushcache, route -n flush,
    // arp -a -d, mdutil -E, diskutil resetUserPermissions, periodic) is root-only and
    // is never invoked here. Only the need-check probes run — identical for dry-run
    // and real runs — so the report says whether the task would do anything at all.

    /// Test seams for the admin probes (real paths/limits by default).
    var periodicBinary = "/usr/sbin/periodic"
    var periodicLog = "/var/log/daily.out"
    var spotlightSlowThreshold: TimeInterval = 3
    /// Mole calls bare `route`; its location moved between /usr/sbin and /sbin
    /// across macOS versions, so resolve it like PATH unless a test pins it.
    var routeBinary = ""

    private var routeExe: String {
        routeBinary.isEmpty
            ? (["/usr/sbin/route", "/sbin/route"].first(where: FileStat.exists) ?? "/usr/sbin/route")
            : routeBinary
    }

    /// Mole `has_active_vpn_interface` (tasks.sh:97-155): a "Connected" network
    /// connection or a full-tunnel utun default route — bare utun* presence is
    /// not enough (iCloud Private Relay, Continuity, #959).
    private enum VPNState { case active, none, unknown }

    private func vpnState() -> VPNState {
        let nc = shell("/usr/sbin/scutil", ["--nc", "list"], 3)
        if nc.timedOut || nc.status != 0 { return .unknown }
        if nc.stdout.split(separator: "\n").contains(where: { $0.hasPrefix("* (Connected)") }) {
            return .active
        }
        // Mole merges stderr; "not in table" means offline, i.e. provably no
        // full-tunnel VPN, while other failures leave the state unknown
        let route = shell("/bin/sh", ["-c", "\(routeExe) -n get default 2>&1"], 3)
        if route.timedOut { return .unknown }
        if route.status != 0 {
            return route.stdout.contains("not in table") ? .none : .unknown
        }
        for line in route.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface",
               parts[1].trimmingCharacters(in: .whitespaces)
                   .range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil {
                return .active
            }
        }
        return .none
    }

    /// tasks.sh opt_network_optimization — VPN gate + mDNSResponder label check.
    /// Mole has no further need-check, so a passing check still needs the helper.
    private func networkOptimization() -> OptimizeOutcome {
        switch vpnState() {
        case .active:
            return OptimizeOutcome(.networkOptimization, .skipped, "VPN 사용 중 — 건너뜀")
        case .unknown:
            return OptimizeOutcome(.networkOptimization, .failed, "VPN 상태 확인 실패")
        case .none: break
        }
        let r = shell("/usr/bin/plutil",
                      ["-extract", "Label", "raw", "-o", "-",
                       "/System/Library/LaunchDaemons/com.apple.mDNSResponder.plist"], 5)
        let label = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.timedOut, r.status == 0,
              label == "com.apple.mDNSResponder" || label == "com.apple.mDNSResponder.reloaded"
        else {
            return OptimizeOutcome(.networkOptimization, .failed,
                                   "mDNSResponder 레이블 확인 실패" + (label.isEmpty ? "" : " (\(label))"))
        }
        return OptimizeOutcome(.networkOptimization, .unavailable,
                               "관리자 권한 필요 — DNS 플러시와 mDNSResponder 시그널은 root 전용 "
                               + "(필요 여부 검사 없이 항상 실행되는 작업)")
    }

    /// tasks.sh opt_network_stack_optimize — flush only when route/DNS checks fail.
    private func networkStackOptimize() -> OptimizeOutcome {
        switch vpnState() {
        case .active:
            return OptimizeOutcome(.networkStackOptimize, .skipped, "VPN 사용 중 — 건너뜀")
        case .unknown:
            return OptimizeOutcome(.networkStackOptimize, .failed, "VPN 상태 확인 실패")
        case .none: break
        }
        let route = shell(routeExe, ["-n", "get", "default"], 3)
        let dns = shell("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "example.com"], 3)
        if route.timedOut || dns.timedOut {
            return OptimizeOutcome(.networkStackOptimize, .failed, "네트워크 상태 확인 타임아웃")
        }
        if route.status < 0 || route.status > 1 || dns.status < 0 || dns.status > 1 {
            return OptimizeOutcome(.networkStackOptimize, .failed, "네트워크 상태 확인 실패")
        }
        if route.status == 0 && dns.status == 0 {
            return OptimizeOutcome(.networkStackOptimize, .unchanged,
                                   "필요 없음 — 라우팅·DNS 정상")
        }
        return OptimizeOutcome(.networkStackOptimize, .unavailable,
                               "관리자 권한 필요 — 라우팅/DNS 오류 감지, 스택 재설정 필요")
    }

    /// tasks.sh opt_disk_permissions_repair / needs_permissions_repair — $HOME not
    /// owned by $USER, or $HOME / ~/Library / ~/Library/Preferences not writable.
    private func diskPermissionsRepair() -> OptimizeOutcome {
        var st = stat()
        var needs = stat(home, &st) == 0 && st.st_uid != getuid()
        if !needs {
            needs = [home, lib, lib + "/Preferences"].contains {
                FileStat.exists($0) && access($0, W_OK) != 0
            }
        }
        if needs {
            return OptimizeOutcome(.diskPermissionsRepair, .unavailable,
                                   "관리자 권한 필요 — 홈 권한 문제 감지 (diskutil resetUserPermissions)")
        }
        return OptimizeOutcome(.diskPermissionsRepair, .unchanged,
                               "필요 없음 — 홈·Library·Preferences 소유·쓰기 정상")
    }

    /// tasks.sh opt_spotlight_index_optimize — rebuild only when the index is
    /// enabled, on AC power, and two timed mdfind probes are both slow.
    private func spotlightIndexOptimize() -> OptimizeOutcome {
        let status = shell("/usr/bin/mdutil", ["-s", "/"], 3)
        guard !status.timedOut, status.status == 0 else {
            return OptimizeOutcome(.spotlightIndexOptimize, .failed, "Spotlight 상태 확인 실패")
        }
        let out = status.stdout
        if out.localizedCaseInsensitiveContains("Indexing disabled") {
            return OptimizeOutcome(.spotlightIndexOptimize, .skipped, "Spotlight 인덱싱이 꺼져 있음")
        }
        guard out.localizedCaseInsensitiveContains("Indexing enabled"),
              !out.localizedCaseInsensitiveContains("Indexing and searching disabled") else {
            return OptimizeOutcome(.spotlightIndexOptimize, .unchanged, "Spotlight 상태 확인됨")
        }
        // Mole: a rebuild is only offered on AC power — skip the probe on battery
        let batt = shell("/usr/bin/pmset", ["-g", "batt"], 3)
        guard batt.stdout.contains("AC Power") else {
            return OptimizeOutcome(.spotlightIndexOptimize, .skipped,
                                   "배터리 사용 중 — 인덱스 재구축 건너뜀")
        }
        var slow = 0, probeFailed = 0
        for probe in 0..<2 {
            let start = Date()
            let r = shell("/usr/bin/mdfind", ["kMDItemFSName == 'Applications'"], 5)
            let elapsed = Date().timeIntervalSince(start)
            if r.timedOut { slow += 1 }                    // a timeout counts as slow (Mole)
            else if r.status != 0 { probeFailed += 1 }
            else if elapsed > spotlightSlowThreshold { slow += 1 }
            if probe == 0 { Thread.sleep(forTimeInterval: 1) }
        }
        if probeFailed > 0 {
            return OptimizeOutcome(.spotlightIndexOptimize, .failed,
                                   "Spotlight 속도 측정 실패 (\(probeFailed)개 프로브)")
        }
        if slow >= 2 {
            return OptimizeOutcome(.spotlightIndexOptimize, .unavailable,
                                   "관리자 권한 필요 — Spotlight 검색이 느림, 인덱스 재구축 필요")
        }
        return OptimizeOutcome(.spotlightIndexOptimize, .unchanged,
                               "필요 없음 — Spotlight 검색 정상")
    }

    /// tasks.sh opt_periodic_maintenance — periodic was removed in macOS 26.
    /// File existence replaces `command -v` so every probe stays a fixed argv;
    /// a missing daily.out log counts as stale.
    private func periodicMaintenance() -> OptimizeOutcome {
        guard FileStat.exists(periodicBinary) else {
            return OptimizeOutcome(.periodicMaintenance, .unavailable, "이 macOS에서 지원 안 함")
        }
        if let mtime = FileStat.modificationDate(periodicLog) {
            let days = max(0, Int(Date().timeIntervalSince(mtime) / 86_400))
            if days < 7 {
                return OptimizeOutcome(.periodicMaintenance, .unchanged,
                                       "필요 없음 — 유지보수가 \(days)일 전에 실행됨")
            }
            return OptimizeOutcome(.periodicMaintenance, .unavailable,
                                   "관리자 권한 필요 — 마지막 유지보수 \(days)일 전")
        }
        return OptimizeOutcome(.periodicMaintenance, .unavailable,
                               "관리자 권한 필요 — 유지보수 실행 기록 없음")
    }
}
