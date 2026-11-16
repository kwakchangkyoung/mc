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

    var selectedCount: Int { selected.count }

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
            List {
                if !model.diagnostics.isEmpty || model.diagnosing {
                    Section("진단 (읽기 전용)") {
                        if model.diagnosing {
                            ProgressView("진단 중…")
                        } else {
                            ForEach(model.diagnostics, id: \.self) { line in
                                Text(line).font(.caption)
                            }
                        }
                    }
                }
                Section("작업") {
                    ForEach(OptimizeTask.allCases) { task in
                        taskRow(task)
                    }
                }
            }
            Divider()
            footer.padding(14)
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

    private func taskRow(_ task: OptimizeTask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(task.title, isOn: Binding(
                    get: { model.selected.contains(task) },
                    set: { isOn in
                        if isOn { model.selected.insert(task) } else { model.selected.remove(task) }
                    }))
                .labelsHidden()
                .disabled(task.requiresAdmin || model.running)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                    Text(task.detail).font(.caption).foregroundStyle(.secondary)
                }
                if task.requiresAdmin {
                    Text("관리자 권한 필요").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            if let outcome = model.results[task] {
                HStack(spacing: 4) {
                    Image(systemName: icon(outcome.kind))
                        .foregroundStyle(color(outcome.kind))
                    Text("\(outcome.kind.koreanLabel): \(outcome.message)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 24)
            }
        }
    }

    private func icon(_ kind: OptimizeOutcomeKind) -> String {
        switch kind {
        case .applied: return "checkmark.circle.fill"
        case .unchanged: return "checkmark.circle"
        case .skipped: return "arrow.right.circle"
        case .unavailable: return "minus.circle"
        case .attention: return "exclamationmark.triangle"
        case .failed: return "xmark.circle"
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
        HStack {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if model.running {
                ProgressView().controlSize(.small)
                Text("최적화 실행 중…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("진단 다시 실행") { model.diagnose() }.disabled(model.diagnosing || model.running)
            Button("실행…") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCount == 0 || model.running)
        }
    }
}
