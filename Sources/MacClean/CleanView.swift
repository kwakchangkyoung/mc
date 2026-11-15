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

    var selectedItems: [CleanItem] {
        (result?.groups ?? []).filter { selected.contains($0.id) && $0.deferred == nil }.flatMap(\.items)
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size.bytes } }

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
                selected = Set(r.groups.filter { !$0.items.isEmpty && $0.deferred == nil }.map(\.id))
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
            if !model.hasFullDiskAccess { FullDiskAccessBanner() }
            content
            Divider()
            footer.padding(14)
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
            placeholder(symbol: "sparkles", title: "정리할 항목을 찾아봅니다",
                        message: "캐시, 로그, 개발 도구 캐시를 스캔합니다. 스캔은 아무것도 삭제하지 않습니다.")
        case .scanning:
            ProgressView("스캔 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cleaning:
            ProgressView("정리 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            if let e = model.execution { ExecutionSummary(result: e) }
        case .ready:
            if let result = model.result { GroupList(result: result, selected: $model.selected) }
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if model.phase == .ready {
                Text("선택됨: \(model.selectedItems.count)개 · \(bytes(model.selectedBytes))").monospacedDigit()
            }
            Spacer()
            Button(model.phase == .ready ? "다시 스캔" : "스캔") { model.scan() }
                .disabled(model.phase == .scanning || model.phase == .cleaning)
            if model.phase == .ready {
                Button("정리…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedItems.isEmpty)
            }
        }
    }

    private func placeholder(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GroupList: View {
    let result: CleanScanResult
    @Binding var selected: Set<String>

    var body: some View {
        List {
            ForEach(CleanSection.allCases) { section in
                let groups = result.groups.filter {
                    $0.rule.section == section && (!$0.items.isEmpty || $0.deferred != nil)
                }
                if !groups.isEmpty {
                    Section(sectionLabel(section)) {
                        ForEach(groups) { GroupRow(group: $0, selected: $selected) }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ s: CleanSection) -> String {
        switch s {
        case .userEssentials: return "사용자 기본"
        case .appCaches: return "앱 캐시"
        case .browsers: return "브라우저"
        case .developerTools: return "개발 도구"
        case .apps: return "앱과 유틸리티"
        }
    }
}

struct GroupRow: View {
    let group: CleanGroup
    @Binding var selected: Set<String>
    @State private var expanded = false

    var body: some View {
        if let deferred = group.deferred {
            HStack {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text(group.rule.label)
                Spacer()
                Text(deferred == .processRunning ? "앱 실행 중이라 건너뜀" : "실행 상태를 확인할 수 없어 건너뜀")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(group.items) { item in
                    HStack {
                        Text(item.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteFormat.string(item.size.bytes, partial: item.size.partial))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if !group.skipped.isEmpty {
                    Text("보호 규칙으로 제외: \(group.skipped.count)개").font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Toggle(isOn: Binding(get: { selected.contains(group.id) },
                                     set: { isOn in
                                         if isOn { selected.insert(group.id) } else { selected.remove(group.id) }
                                     })) {
                    HStack {
                        Text(group.rule.label)
                        Spacer()
                        Text("\(group.items.count)개 · \(ByteFormat.string(group.totalBytes, partial: group.partial))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ExecutionSummary: View {
    let result: CleanExecutionResult

    var body: some View {
        List {
            Section {
                Label("\(bytes(result.removedBytes)) 확보 · \(result.removedCount)개 삭제", systemImage: "checkmark.circle")
                    .font(.title3)
            }
            if !result.skipped.isEmpty {
                Section("건너뜀 \(result.skipped.count)개") {
                    ForEach(result.skipped.indices, id: \.self) { i in
                        row(result.skipped[i].path, result.skipped[i].reason)
                    }
                }
            }
            if !result.failed.isEmpty {
                Section("실패 \(result.failed.count)개") {
                    ForEach(result.failed.indices, id: \.self) { i in
                        row(result.failed[i].path, result.failed[i].message)
                    }
                }
            }
        }
    }

    private func row(_ path: String, _ reason: String) -> some View {
        HStack {
            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("전체 디스크 접근 권한이 없어 휴지통, Mail, 일부 앱 데이터는 스캔하지 못합니다.")
            Spacer()
            Button("설정 열기") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
        .font(.callout)
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}
