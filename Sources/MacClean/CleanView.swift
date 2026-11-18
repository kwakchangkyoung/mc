import MacCleanCore
import SwiftUI

@MainActor
final class CleanModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, ready, cleaning, done }

    @Published var phase: Phase = .idle
    @Published var result: CleanScanResult?
    @Published var selected: Set<String> = []        // rule ids
    @Published var execution: CleanExecutionResult?
    @Published var error: String?
    @Published var hasFullDiskAccess = AppEnvironment.current.hasFullDiskAccess()

    var selectableGroupIDs: Set<String> {
        Set((result?.groups ?? []).filter { !$0.items.isEmpty && $0.deferred == nil }.map(\.id))
    }

    var allSelected: Bool {
        let all = selectableGroupIDs
        return !all.isEmpty && all.isSubset(of: selected)
    }

    var selectedItems: [CleanItem] {
        (result?.groups ?? []).filter { selected.contains($0.id) && $0.deferred == nil }.flatMap(\.items)
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size.bytes } }

    func toggleSelectAll() {
        let all = selectableGroupIDs
        if allSelected {
            selected.removeAll()
        } else {
            selected = all
        }
    }

    func scan() {
        phase = .scanning
        execution = nil
        error = nil
        hasFullDiskAccess = AppEnvironment.current.hasFullDiskAccess()
        Task {
            do {
                let engine = try AppEnvironment.current.makeCleanEngine()
                let r = await Task.detached(priority: .userInitiated) { engine.scan() }.value
                result = r
                selected = Set(r.groups.filter {
                    !$0.items.isEmpty && $0.deferred == nil && $0.rule.defaultSelected
                }.map(\.id))
                phase = .ready
            } catch {
                self.error = "화이트리스트 파일을 읽을 수 없어 정리를 중단했습니다: \(error)"
                phase = .idle
            }
        }
    }

    func clean() {
        let items = selectedItems
        phase = .cleaning
        Task {
            do {
                let engine = try AppEnvironment.current.makeCleanEngine()
                execution = await Task.detached(priority: .userInitiated) { engine.execute(items) }.value
                result = nil
                phase = .done
            } catch {
                self.error = "화이트리스트 파일을 읽을 수 없어 정리를 중단했습니다: \(error)"
                phase = .ready
            }
        }
    }
}

struct CleanView: View {
    @ObservedObject var model: CleanModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeaderBar(pane: .clean) {
                if model.phase == .ready, let res = model.result {
                    HStack(spacing: 10) {
                        StatusPill(
                            text: "총 발견 \(bytes(res.totalBytes))",
                            color: .teal,
                            icon: "sparkles"
                        )
                        Button(model.allSelected ? "전체 해제" : "전체 선택") {
                            model.toggleSelectAll()
                        }
                        .controlSize(.small)
                        .disabled(model.selectableGroupIDs.isEmpty)
                    }
                }
            }
            Divider()
            if !model.hasFullDiskAccess { FullDiskAccessBanner() }
            content
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
        .confirmationDialog("선택한 \(model.selectedItems.count)개 항목(\(bytes(model.selectedBytes)))을 삭제할까요?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("영구 삭제", role: .destructive) { model.clean() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("캐시와 로그는 휴지통을 거치지 않고 바로 삭제됩니다. 삭제 직전에 안전 검사를 다시 수행합니다.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            idleHero
        case .scanning:
            loadingState(title: "정리 대상을 스캔하고 있습니다…", subtitle: "안전 규칙과 화이트리스트를 대조하며 용량을 계산합니다.")
        case .cleaning:
            loadingState(title: "선택한 항목을 정리하고 있습니다…", subtitle: "삭제 직전 dev:inode 및 실행 중 프로세스를 다시 검사합니다.")
        case .done:
            if let e = model.execution { ExecutionSummary(result: e) }
        case .ready:
            if let result = model.result { GroupList(result: result, selected: $model.selected) }
        }
    }

    private var idleHero: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.teal.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.teal)
            }
            VStack(spacing: 6) {
                Text("안전하게 맥의 여유 공간을 확보하세요")
                    .font(.title2.weight(.bold))
                Text("사용자 캐시, 로그, 브라우저 캐시, Xcode · 개발 도구 캐시를 스캔합니다.\n스캔은 읽기 전용(Dry-run)으로 동작하며 아무것도 삭제하지 않습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            HStack(spacing: 10) {
                categoryChip(icon: "folder.badge.gearshape", text: "사용자 앱 캐시·로그")
                categoryChip(icon: "globe", text: "브라우저 캐시")
                categoryChip(icon: "hammer.fill", text: "Xcode · 개발 도구")
                categoryChip(icon: "lock.shield.fill", text: "실행 중 앱 보호")
            }
            Button {
                model.scan()
            } label: {
                Label("스캔 시작하기", systemImage: "magnifyingglass")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func categoryChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.teal)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
    }

    private func loadingState(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if model.phase == .ready {
                HStack(spacing: 8) {
                    Text("선택된 항목")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(model.selectedItems.count)개")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(bytes(model.selectedBytes))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.teal)
                        .monospacedDigit()
                }
            } else {
                Text("모든 삭제 작업은 SafeDeleter 안전 정책을 거칩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.scan()
            } label: {
                Label(model.phase == .ready || model.phase == .done ? "다시 스캔" : "스캔",
                      systemImage: "arrow.clockwise")
            }
            .disabled(model.phase == .scanning || model.phase == .cleaning)

            if model.phase == .ready {
                Button {
                    confirming = true
                } label: {
                    Label("선택 항목 정리…", systemImage: "sparkles")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(model.selectedItems.isEmpty)
            }
        }
    }
}

struct GroupList: View {
    let result: CleanScanResult
    @Binding var selected: Set<String>

    var body: some View {
        List {
            ForEach(CleanSection.allCases) { section in
                let groups = result.groups.filter {
                    $0.rule.section == section
                        && (!$0.items.isEmpty || $0.deferred != nil || $0.note != nil)
                }
                if !groups.isEmpty {
                    let sectionBytes = groups.reduce(Int64(0)) { $0 + $1.totalBytes }
                    Section {
                        ForEach(groups) { GroupRow(group: $0, selected: $selected) }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: sectionIcon(section))
                                .foregroundStyle(.teal)
                            Text(sectionLabel(section))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if sectionBytes > 0 {
                                Text(ByteFormat.string(sectionBytes))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func sectionLabel(_ s: CleanSection) -> String {
        switch s {
        case .userEssentials: return "사용자 기본"
        case .appCaches: return "앱 캐시 및 컨테이너"
        case .browsers: return "웹 브라우저 캐시"
        case .developerTools: return "개발 도구 및 빌드 캐시"
        case .apps: return "앱과 유틸리티"
        }
    }

    private func sectionIcon(_ s: CleanSection) -> String {
        switch s {
        case .userEssentials: return "person.crop.circle.fill"
        case .appCaches: return "square.stack.3d.up.fill"
        case .browsers: return "globe"
        case .developerTools: return "hammer.fill"
        case .apps: return "app.badge.checkmark.fill"
        }
    }
}

struct GroupRow: View {
    let group: CleanGroup
    @Binding var selected: Set<String>
    @State private var expanded = false

    var body: some View {
        if let deferred = group.deferred {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(koreanRuleLabel(group.rule.label))
                        .fontWeight(.medium)
                    Text(group.rule.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                StatusPill(
                    text: deferred == .processRunning ? "앱 실행 중 · 자동 보류" : "상태 확인 불가 · 보류",
                    color: .orange,
                    icon: "lock.fill"
                )
            }
            .padding(.vertical, 3)
        } else if group.items.isEmpty {
            // fail-closed or nothing to offer — show the reason instead of a toggle
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(koreanRuleLabel(group.rule.label))
                        .fontWeight(.medium)
                    if let note = group.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !group.skipped.isEmpty {
                    StatusPill(text: "사용 중 \(group.skipped.count)개 제외", color: .secondary,
                               icon: "checkmark.shield")
                }
            }
            .padding(.vertical, 3)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(group.items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(ByteFormat.string(item.size.bytes, partial: item.size.partial))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
                if !group.skipped.isEmpty {
                    Label("보호 규칙으로 자동 제외됨: \(group.skipped.count)개", systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            } label: {
                Toggle(isOn: Binding(get: { selected.contains(group.id) },
                                     set: { isOn in
                                         if isOn { selected.insert(group.id) } else { selected.remove(group.id) }
                                     })) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(koreanRuleLabel(group.rule.label))
                                .fontWeight(.medium)
                            Text(group.rule.patterns.first ?? group.rule.label)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            if let note = group.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        StatusPill(text: "\(group.items.count)개", color: .secondary)
                        Text(ByteFormat.string(group.totalBytes, partial: group.partial))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(minWidth: 76, alignment: .trailing)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct ExecutionSummary: View {
    let result: CleanExecutionResult

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.14)).frame(width: 52, height: 52)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(bytes(result.removedBytes)) 확보 완료")
                            .font(.title2.weight(.bold))
                        Text("총 \(result.removedCount)개 캐시·로그 항목을 안전하게 정리했습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            if !result.skipped.isEmpty {
                Section("안전 정책으로 건너뜀 (\(result.skipped.count)개)") {
                    ForEach(result.skipped.indices, id: \.self) { i in
                        row(result.skipped[i].path, result.skipped[i].reason, color: .secondary)
                    }
                }
            }
            if !result.failed.isEmpty {
                Section("삭제 실패 (\(result.failed.count)개)") {
                    ForEach(result.failed.indices, id: \.self) { i in
                        row(result.failed[i].path, result.failed[i].message, color: .red)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ path: String, _ reason: String, color: Color) -> some View {
        HStack {
            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            StatusPill(text: reason, color: color)
        }
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("전체 디스크 접근 권한이 필요합니다")
                    .font(.callout.weight(.semibold))
                Text("권한이 없으면 휴지통, Safari, Mail 및 일부 샌드박스 컨테이너 캐시를 스캔할 수 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("권한 설정 열기") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }
}

func koreanRuleLabel(_ label: String) -> String {
    let map: [String: String] = [
        "User app cache": "사용자 앱 캐시",
        "User app logs": "사용자 앱 로그",
        "Trash": "휴지통",
        "Recent items": "최근 사용 항목 기록",
        "Saved application state": "앱 저장 상태 (Saved State)",
        "Apple system caches": "Apple 시스템 서비스 캐시",
        "Diagnostic reports": "진단 리포트 (DiagnosticReports)",
        "Incomplete downloads": "미완료 다운로드 임시 파일",
        "Identity & suggestions caches": "연락처·제안 캐시",
        "Crash reporter": "크래시 리포트 (30일 경과)",
        "Apple container caches": "Apple 컨테이너 캐시",
        "Sandboxed app caches": "샌드박스 앱 컨테이너 캐시",
        "Group container logs": "그룹 컨테이너 로그",
        "Handoff clipboard": "Handoff 공유 클립보드",
        "Safari cache": "Safari 브라우저 캐시",
        "Chrome cache": "Google Chrome 캐시",
        "Edge cache": "Microsoft Edge 캐시",
        "Brave cache": "Brave 브라우저 캐시",
        "Arc cache": "Arc 브라우저 캐시",
        "Firefox cache": "Mozilla Firefox 캐시",
        "npm cache": "npm 패키지 캐시",
        "Python caches": "Python 도구 캐시 (pyenv · poetry · ruff · pytest)",
        "Cargo registry cache": "Rust Cargo · Rustup 캐시",
        "Ruby caches": "Ruby Gem · Bundler 캐시",
        "Container & cloud CLI caches": "Docker · Kubernetes · 클라우드 CLI 캐시",
        "Frontend tool caches": "프론트엔드 빌드 도구 캐시 (Vite · Webpack · Turbo)",
        "Shell caches": "셸 플러그인 캐시 (oh-my-zsh · pre-commit)",
        "Xcode DerivedData": "Xcode DerivedData 빌드 산출물",
        "Xcode caches & products": "Xcode 캐시 및 아카이브 산출물",
        "Simulator caches & logs": "iOS 시뮬레이터 캐시 및 로그",
        "Swift & Android build caches": "SwiftPM 및 Android 빌드 캐시",
        "CPAN build artifacts": "Perl CPAN 빌드 캐시",
        "Clang module cache": "Clang 컴파일러 모듈 캐시",
        "Other toolchain caches": "기타 개발 툴체인 캐시 (Bazel · Zig · Terraform 등)",
        "VS Code caches": "Visual Studio Code 캐시 및 로그",
        "Shell history temp files": "셸 임시 히스토리 파일 (.zcompdump 등)",
        "Chat app caches": "메신저 앱 캐시 (Discord · Slack)",
        "Aerial wallpaper videos": "에어리얼 배경화면 영상",
    ]
    return map[label] ?? label
}
