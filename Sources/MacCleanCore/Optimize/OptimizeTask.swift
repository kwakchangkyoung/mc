import Foundation

/// Mole `lib/optimize/catalog.sh` — the 19 registered optimize tasks, in execution order.
/// `requiresAdmin` mirrors the doc's admin column; admin tasks need the M6 privileged helper
/// and return `.unavailable` here instead of running.
public enum OptimizeTask: String, CaseIterable, Sendable, Identifiable {
    case cacheRefresh = "cache_refresh"
    case savedStateCleanup = "saved_state_cleanup"
    case fixBrokenConfigs = "fix_broken_configs"
    case networkOptimization = "network_optimization"
    case sqliteVacuum = "sqlite_vacuum"
    case preventNetworkDsstore = "prevent_network_dsstore"
    case legacyOverridesAudit = "legacy_overrides_audit"
    case networkStackOptimize = "network_stack_optimize"
    case diskPermissionsRepair = "disk_permissions_repair"
    case spotlightIndexOptimize = "spotlight_index_optimize"
    case spotlightOrphanRulesCleanup = "spotlight_orphan_rules_cleanup"
    case periodicMaintenance = "periodic_maintenance"
    case sharedFileListRepair = "shared_file_list_repair"
    case diskVerify = "disk_verify"
    case loginItemsAudit = "login_items_audit"
    case quarantineCleanup = "quarantine_cleanup"
    case launchAgentsCleanup = "launch_agents_cleanup"
    case notificationCleanup = "notification_cleanup"
    case coreduetCleanup = "coreduet_cleanup"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cacheRefresh: return "Finder 캐시 새로고침"
        case .savedStateCleanup: return "앱 상태 정리"
        case .fixBrokenConfigs: return "손상된 설정 복구"
        case .networkOptimization: return "네트워크 캐시 새로고침"
        case .sqliteVacuum: return "데이터베이스 최적화"
        case .preventNetworkDsstore: return "네트워크 .DS_Store 방지"
        case .legacyOverridesAudit: return "레거시 오버라이드 정리"
        case .networkStackOptimize: return "네트워크 스택 새로고침"
        case .diskPermissionsRepair: return "권한 복구"
        case .spotlightIndexOptimize: return "Spotlight 최적화"
        case .spotlightOrphanRulesCleanup: return "Spotlight 고아 규칙 정리"
        case .periodicMaintenance: return "주기적 유지보수"
        case .sharedFileListRepair: return "공유 파일 목록 복구"
        case .diskVerify: return "디스크 상태 점검"
        case .loginItemsAudit: return "로그인 항목 점검"
        case .quarantineCleanup: return "격리 기록 정리"
        case .launchAgentsCleanup: return "LaunchAgent 점검"
        case .notificationCleanup: return "알림 기록 정리"
        case .coreduetCleanup: return "사용 기록 정리"
        }
    }

    public var detail: String {
        switch self {
        case .cacheRefresh:
            return "QuickLook·아이콘 캐시를 리셋하고 캐시 디렉터리를 삭제합니다."
        case .savedStateCleanup:
            return "30일 지난 저장 상태(*.savedState)를 삭제합니다."
        case .fixBrokenConfigs:
            return "깨진 서드파티 환경설정(.plist) 파일을 찾아 삭제합니다."
        case .networkOptimization:
            return "DNS 캐시를 비웁니다. VPN 사용 중에는 건너뜁니다."
        case .sqliteVacuum:
            return "Mail·메시지·Safari SQLite 데이터베이스를 VACUUM합니다. 전체 디스크 접근 권한이 필요할 수 있습니다."
        case .preventNetworkDsstore:
            return "네트워크/USB 볼륨에 .DS_Store가 생기지 않도록 설정합니다."
        case .legacyOverridesAudit:
            return "옛 트윅 도구가 남긴 숨은 시스템 오버라이드를 제거합니다."
        case .networkStackOptimize:
            return "라우팅 테이블과 ARP 캐시를 비웁니다. 문제가 감지될 때만 실행됩니다."
        case .diskPermissionsRepair:
            return "홈 디렉터리 소유권·권한이 깨졌을 때 초기화합니다."
        case .spotlightIndexOptimize:
            return "검색이 느릴 때만 Spotlight 인덱스를 재구축합니다."
        case .spotlightOrphanRulesCleanup:
            return "삭제된 앱의 Spotlight 규칙 항목을 제거합니다."
        case .periodicMaintenance:
            return "macOS periodic daily/weekly/monthly 스크립트를 실행합니다."
        case .sharedFileListRepair:
            return "손상된 .sfl2/.sfl3/.sfl4 파일을 삭제합니다."
        case .diskVerify:
            return "파일시스템을 검증합니다. 기본 비활성화(MACCLEAN_ENABLE_DISK_VERIFY=1)."
        case .loginItemsAudit:
            return "깨진 로그인 항목을 찾아 보고합니다. 삭제하지 않습니다."
        case .quarantineCleanup:
            return "Gatekeeper 다운로드 이력(격리 DB)을 삭제합니다."
        case .launchAgentsCleanup:
            return "프로그램이 사라진 LaunchAgent를 찾아 보고합니다. 삭제하지 않습니다."
        case .notificationCleanup:
            return "30일 지난 알림 레코드를 삭제합니다."
        case .coreduetCleanup:
            return "90일 지난 사용 추적(Knowledge) 레코드를 삭제합니다."
        }
    }

    /// Mole admin column: 4/8/9/10/12 need sudo. (login_items_audit의 sudo는 선택적 BTM
    /// 덤프뿐이라 사용자 작업으로 분류한다.)
    public var requiresAdmin: Bool {
        switch self {
        case .networkOptimization, .networkStackOptimize, .diskPermissionsRepair,
             .spotlightIndexOptimize, .periodicMaintenance:
            return true
        default:
            return false
        }
    }

    /// Extra ids Mole's whitelist also accepts for this task (tasks.sh:2118).
    public var legacyWhitelistIDs: [String] {
        self == .networkOptimization ? ["system_maintenance"] : []
    }
}

/// Mole outcome model (outcomes.sh:11-17).
public enum OptimizeOutcomeKind: String, Sendable, CaseIterable {
    case applied       // 변경 완료 (dry-run에서는 완료 예정)
    case unchanged     // 검사 완료, 변경 불필요
    case skipped       // 정책/컨텍스트로 의도적 미실행
    case unavailable   // 호스트가 기능 미제공(권한 없음, 도구 없음, 타임아웃)
    case attention     // 사용자 조치가 필요한 문제 발견
    case failed        // 작업 실패

    public var koreanLabel: String {
        switch self {
        case .applied: return "적용됨"
        case .unchanged: return "변경 없음"
        case .skipped: return "건너뜀"
        case .unavailable: return "실행 불가"
        case .attention: return "확인 필요"
        case .failed: return "실패"
        }
    }
}

public struct OptimizeOutcome: Sendable {
    public let task: OptimizeTask
    public let kind: OptimizeOutcomeKind
    public let message: String
    /// Per-item notes (e.g. broken items found by a report-only task).
    public var detail: [String] = []

    public init(_ task: OptimizeTask, _ kind: OptimizeOutcomeKind, _ message: String,
                detail: [String] = []) {
        self.task = task
        self.kind = kind
        self.message = message
        self.detail = detail
    }

    /// Mole `optimize_task_result_from_counts`: 부분 실패도 failed.
    static func fromCounts(_ task: OptimizeTask, applied: Int, failed: Int, skipped: Int,
                           message: @autoclosure () -> String) -> OptimizeOutcome {
        if failed > 0 { return OptimizeOutcome(task, .failed, "\(message()) — \(failed)개 실패") }
        if applied > 0 { return OptimizeOutcome(task, .applied, message()) }
        if skipped > 0 { return OptimizeOutcome(task, .skipped, "\(message()) — \(skipped)개 건너뜀") }
        return OptimizeOutcome(task, .unchanged, message())
    }
}

/// Mole `~/.config/mole/whitelist_optimize` — one task id per line, `#` comments.
/// Read-only: MacClean never writes this file.
public struct OptimizeWhitelist: Sendable {
    public let ids: Set<String>

    public init(ids: Set<String>) { self.ids = ids }

    public static func load(file: URL) -> OptimizeWhitelist {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return OptimizeWhitelist(ids: [])
        }
        return OptimizeWhitelist(ids: Set(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }))
    }

    public func contains(_ task: OptimizeTask) -> Bool {
        ids.contains(task.id) || task.legacyWhitelistIDs.contains { ids.contains($0) }
    }
}
