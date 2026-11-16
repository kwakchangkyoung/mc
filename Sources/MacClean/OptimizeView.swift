import MacCleanCore
import SwiftUI

@MainActor
final class OptimizeModel: ObservableObject {
    @Published var diagnostics: [String] = []
    @Published var diagnosing = false
    @Published var selected: Set<OptimizeTask> = Set(OptimizeTask.allCases.filter { !$0.requiresAdmin })
    @Published var results: [OptimizeTask: OptimizeOutcome] = [:]
    @Published var running = false
    @Published var error: String?

    var runnableTasks: Set<OptimizeTask> {
        Set(OptimizeTask.allCases.filter { !$0.requiresAdmin })
    }

    var allSelected: Bool {
        runnableTasks.isSubset(of: selected)
    }

    var selectedCount: Int { selected.count }

    func toggleSelectAll() {
        if allSelected {
            selected.removeAll()
        } else {
            selected = runnableTasks
        }
    }

    func diagnose() {
        guard !diagnosing else { return }
        diagnosing = true
        Task {
            diagnostics = await Task.detached(priority: .userInitiated) {
                OptimizeDiagnostics.run()
            }.value
            diagnosing = false
        }
    }

    func runSelected() {
        running = true
        error = nil
        let tasks = OptimizeTask.allCases.filter { selected.contains($0) }
        Task {
            do {
                let engine = try AppEnvironment.current.makeOptimizeEngine()
                let probes = await Task.detached(priority: .userInitiated) { ProbeContext.capture() }.value
                for task in tasks {
                    let outcome = await Task.detached(priority: .userInitiated) {
                        engine.run(task, dryRun: false, probes: probes)
                    }.value
                    results[task] = outcome
                }
            } catch {
                self.error = "화이트리스트 파일을 읽을 수 없어 중단했습니다: \(error)"
            }
            running = false
        }
    }
}

struct OptimizeView: View {
    @ObservedObject var model: OptimizeModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeaderBar(pane: .optimize) {
                HStack(spacing: 10) {
                    StatusPill(
                        text: "사용자 작업 \(model.runnableTasks.count)종 가능",
                        color: .orange,
                        icon: "bolt.shield.fill"
                    )
                    Button(model.allSelected ? "전체 해제" : "전체 선택") {
                        model.toggleSelectAll()
                    }
                    .controlSize(.small)
                    .disabled(model.running)
                }
            }
            Divider()
            diagnosticsCard
            Divider()
            List {
                Section {
                    ForEach(OptimizeTask.allCases) { task in
                        taskRow(task)
                    }
                } header: {
                    HStack {
                        Label("유지보수 및 최적화 카탈로그 (\(OptimizeTask.allCases.count)개 작업)", systemImage: "checklist")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if !model.results.isEmpty {
                            let appliedCount = model.results.values.filter { $0.kind == .applied }.count
                            Text("적용됨 \(appliedCount)건")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
        .onAppear { if model.diagnostics.isEmpty { model.diagnose() } }
        .confirmationDialog("선택한 \(model.selectedCount)개 최적화 작업을 실행할까요?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("실행", role: .destructive) { model.runSelected() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("시스템 설정·캐시·데이터베이스가 변경될 수 있습니다. 실행 전 검사 결과를 확인하세요.")
        }
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("시스템 사전 진단 (읽기 전용)", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                if model.diagnosing {
                    ProgressView().controlSize(.small)
                }
            }

            if model.diagnosing && model.diagnostics.isEmpty {
                Text("시스템 지표를 점검하고 있습니다…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.diagnostics.isEmpty {
                Text("진단 항목 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowDiagnosticsView(lines: model.diagnostics)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func taskRow(_ task: OptimizeTask) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if task.requiresAdmin {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            } else {
                Toggle(task.title, isOn: Binding(
                    get: { model.selected.contains(task) },
                    set: { isOn in
                        if isOn { model.selected.insert(task) } else { model.selected.remove(task) }
                    }))
                .labelsHidden()
                .disabled(model.running)
                .frame(width: 20)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill((task.requiresAdmin ? Color.secondary : Color.orange).opacity(0.13))
                    .frame(width: 28, height: 28)
                Image(systemName: taskSymbol(task))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(task.requiresAdmin ? Color.secondary : Color.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .fontWeight(.medium)
                        .foregroundStyle(task.requiresAdmin ? Color.secondary : Color.primary)
                    if task.requiresAdmin {
                        StatusPill(text: "관리자 권한 필요", color: .secondary, icon: "lock.fill")
                    }
                }
                Text(task.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let outcome = model.results[task] {
                    HStack(spacing: 6) {
                        StatusPill(
                            text: outcome.kind.koreanLabel,
                            color: color(outcome.kind),
                            icon: icon(outcome.kind)
                        )
                        Text(outcome.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func taskSymbol(_ task: OptimizeTask) -> String {
        switch task {
        case .cacheRefresh: return "arrow.triangle.2.circlepath"
        case .savedStateCleanup: return "clock.arrow.circlepath"
        case .fixBrokenConfigs: return "wrench.and.screwdriver.fill"
        case .networkOptimization, .networkStackOptimize: return "network"
        case .sqliteVacuum: return "cylinder.split.1x2.fill"
        case .preventNetworkDsstore: return "externaldrive.badge.checkmark"
        case .legacyOverridesAudit: return "magnifyingglass.circle.fill"
        case .diskPermissionsRepair: return "lock.open.rotation"
        case .spotlightIndexOptimize, .spotlightOrphanRulesCleanup: return "sparkle.magnifyingglass"
        case .periodicMaintenance: return "calendar.badge.clock"
        case .sharedFileListRepair: return "list.bullet.rectangle.fill"
        case .diskVerify: return "internaldrive.fill"
        case .loginItemsAudit, .launchAgentsCleanup: return "person.badge.key.fill"
        case .quarantineCleanup: return "checkmark.shield.fill"
        case .notificationCleanup: return "bell.slash.fill"
        case .coreduetCleanup: return "chart.bar.xaxis"
        }
    }

    private func icon(_ kind: OptimizeOutcomeKind) -> String {
        switch kind {
        case .applied: return "checkmark.circle.fill"
        case .unchanged: return "checkmark.circle"
        case .skipped: return "arrow.right.circle"
        case .unavailable: return "minus.circle"
        case .attention: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(_ kind: OptimizeOutcomeKind) -> Color {
        switch kind {
        case .applied: return .green
        case .unchanged: return .secondary
        case .skipped: return .blue
        case .unavailable: return .secondary
        case .attention: return .orange
        case .failed: return .red
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if model.running {
                ProgressView().controlSize(.small)
                Text("선택한 최적화 작업을 실행하고 있습니다…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("선택된 작업")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(model.selectedCount)개")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button {
                model.diagnose()
            } label: {
                Label("진단 다시 실행", systemImage: "arrow.clockwise")
            }
            .disabled(model.diagnosing || model.running)

            Button {
                confirming = true
            } label: {
                Label("선택 작업 실행…", systemImage: "bolt.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(model.selectedCount == 0 || model.running)
        }
    }
}

struct FlowDiagnosticsView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines, id: \.self) { line in
                HStack(spacing: 8) {
                    Image(systemName: line.contains("주의") || line.contains("경고") || line.contains("권장")
                          ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(line.contains("주의") || line.contains("경고") || line.contains("권장")
                                         ? .orange : .green)
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.88))
                    Spacer()
                }
            }
        }
    }
}
