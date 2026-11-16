import MacCleanCore
import SwiftUI

@MainActor
final class UninstallModel: ObservableObject {
    enum Phase: Equatable { case list, loading, planning, ready, removing, done }

    @Published var phase: Phase = .list
    @Published var apps: [InstalledApp] = []
    @Published var query = ""
    @Published var plan: UninstallPlan?
    @Published var selected: Set<String> = []
    @Published var execution: UninstallResult?
    @Published var error: String?

    var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return apps }
        return apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var selectedItems: [LeftoverItem] {
        guard let plan else { return [] }
        return ([plan.bundleItem] + plan.leftovers).filter { selected.contains($0.path) && !$0.requiresAdmin }
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size.bytes } }

    func loadApps() {
        phase = .loading
        error = nil
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [InstalledApp] in
                guard let deleter = try? AppEnvironment.current.makeDeleter() else { return [] }
                return AppInventory(home: AppEnvironment.current.home)
                    .scan(protection: deleter.policy.protection)
            }.value
            apps = found
            phase = .list
        }
    }

    func select(_ app: InstalledApp) {
        phase = .planning
        plan = nil
        execution = nil
        error = nil
        Task {
            let p = await Task.detached(priority: .userInitiated) { () -> UninstallPlan? in
                guard let engine = try? AppEnvironment.current.makeUninstallEngine() else { return nil }
                let inventory = AppInventory(home: AppEnvironment.current.home)
                let all = inventory.scan(protection: engine.deleter.policy.protection)
                let siblings = UninstallEngine.siblings(of: app, in: all)
                return engine.plan(for: app, siblings: siblings, probes: ProbeContext.capture())
            }.value
            if let p {
                plan = p
                // everything checked by default except admin-only items
                selected = Set(([p.bundleItem] + p.leftovers)
                    .filter { !$0.requiresAdmin }.map(\.path))
                phase = .ready
            } else {
                error = "화이트리스트 파일을 읽을 수 없어 중단했습니다."
                phase = .list
            }
        }
    }

    func uninstall() {
        guard let plan else { return }
        let items = selectedItems
        phase = .removing
        Task {
            do {
                let engine = try AppEnvironment.current.makeUninstallEngine()
                let probes = await Task.detached(priority: .userInitiated) { ProbeContext.capture() }.value
                execution = try await Task.detached(priority: .userInitiated) {
                    try engine.execute(app: plan.app, items: items, probes: probes)
                }.value
                phase = .done
            } catch UninstallError.appRunning(let name) {
                error = "\(name)이(가) 실행 중입니다. 앱을 종료한 뒤 다시 시도하세요."
                phase = .ready
            } catch UninstallError.processStateUnknown {
                error = "실행 상태를 확인할 수 없어 삭제를 중단했습니다."
                phase = .ready
            } catch UninstallError.officialUninstallerRequired(let vendor) {
                error = "\(vendor) 공식 언인스톨러가 필요한 앱입니다."
                phase = .ready
            } catch {
                self.error = "화이트리스트 파일을 읽을 수 없어 중단했습니다: \(error)"
                phase = .ready
            }
        }
    }

    func back() {
        plan = nil
        execution = nil
        loadApps()
    }
}

struct UninstallView: View {
    @ObservedObject var model: UninstallModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer.padding(14)
        }
        .onAppear { if model.apps.isEmpty && model.phase == .list { model.loadApps() } }
        .confirmationDialog("\"\(model.plan?.app.name ?? "")\"과(와) 선택한 항목을 휴지통으로 이동할까요?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("휴지통으로 이동", role: .destructive) { model.uninstall() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("앱 번들과 \(model.selectedItems.count)개 관련 파일(\(bytes(model.selectedBytes)))이 이동됩니다. 이동 전에 안전 검사를 다시 수행합니다.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .list:
            appList
        case .loading:
            ProgressView("앱 목록을 읽는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .planning:
            ProgressView("관련 파일을 찾는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .removing:
            ProgressView("휴지통으로 이동 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let plan = model.plan { leftoverList(plan) }
        case .done:
            if let e = model.execution { uninstallSummary(e) }
        }
    }

    // MARK: app list

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("앱 검색", text: $model.query).textFieldStyle(.plain)
            }
            .padding(8)
            Divider()
            List(model.filtered) { app in
                Button { model.select(app) } label: {
                    HStack {
                        Image(systemName: "app").foregroundStyle(Color.accentColor).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        if app.officialUninstaller != nil {
                            Text("공식 언인스톨러 필요").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Text(lastUsed(app.lastUsed)).font(.caption).foregroundStyle(.secondary)
                        Text(ByteFormat.string(app.size.bytes, partial: app.size.partial))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func lastUsed(_ date: Date?) -> String {
        guard let date else { return "" }
        let days = Int(-date.timeIntervalSinceNow / 86_400)
        if days <= 0 { return "오늘 사용" }
        if days == 1 { return "어제 사용" }
        if days < 30 { return "\(days)일 전" }
        if days < 365 { return "\(days / 30)개월 전" }
        return "\(days / 365)년 전"
    }

    // MARK: leftover list

    private func leftoverList(_ plan: UninstallPlan) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.app.name).font(.headline)
                    Text("\(plan.app.bundleID) · \(plan.app.path)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(ByteFormat.string(plan.app.size.bytes, partial: plan.app.size.partial))
                    .monospacedDigit()
            }
            .padding(10)
            Divider()
            List {
                leftoverRow(plan.bundleItem, fixed: true)
                ForEach(plan.leftovers) { item in
                    leftoverRow(item, fixed: false)
                }
                if !plan.skipped.isEmpty {
                    Section("보호 규칙으로 제외 \(plan.skipped.count)개") {
                        ForEach(plan.skipped.indices, id: \.self) { i in
                            HStack {
                                Text(plan.skipped[i].path).font(.caption.monospaced())
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(plan.skipped[i].reason.rawValue).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func leftoverRow(_ item: LeftoverItem, fixed: Bool) -> some View {
        HStack {
            if item.requiresAdmin {
                Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 18)
            } else {
                Toggle("", isOn: Binding(
                    get: { fixed || model.selected.contains(item.path) },
                    set: { isOn in
                        if isOn { model.selected.insert(item.path) } else { model.selected.remove(item.path) }
                    }))
                .labelsHidden().disabled(fixed)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                if item.requiresAdmin {
                    Text("관리자 권한 필요").font(.caption2).foregroundStyle(.orange)
                } else if item.sensitive {
                    Text("개인 데이터 포함 가능").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(ByteFormat.string(item.size.bytes, partial: item.size.partial))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: summary + footer

    private func uninstallSummary(_ result: UninstallResult) -> some View {
        List {
            Section {
                Label("\(bytes(result.removedBytes)) 확보 · \(result.removedCount)개를 휴지통으로 이동",
                      systemImage: "checkmark.circle").font(.title3)
            }
            if !result.skipped.isEmpty {
                Section("건너뜀 \(result.skipped.count)개") {
                    ForEach(result.skipped.indices, id: \.self) { i in
                        summaryRow(result.skipped[i].path, result.skipped[i].reason)
                    }
                }
            }
            if !result.failed.isEmpty {
                Section("실패 \(result.failed.count)개") {
                    ForEach(result.failed.indices, id: \.self) { i in
                        summaryRow(result.failed[i].path, result.failed[i].message)
                    }
                }
            }
        }
    }

    private func summaryRow(_ path: String, _ reason: String) -> some View {
        HStack {
            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if model.phase == .ready {
                Text("선택됨: \(model.selectedItems.count)개 · \(bytes(model.selectedBytes))")
                    .monospacedDigit()
            }
            Spacer()
            if model.phase == .list {
                Button("다시 스캔") { model.loadApps() }
            }
            if model.phase == .ready {
                Button("삭제…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedItems.isEmpty || model.plan?.app.officialUninstaller != nil)
            }
            if model.phase == .done {
                Button("목록으로") { model.back() }
            }
        }
    }
}


