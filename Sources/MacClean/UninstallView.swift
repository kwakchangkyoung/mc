import AppKit
import MacCleanCore
import SwiftUI

@MainActor
final class UninstallModel: ObservableObject {
    enum Phase: Equatable { case list, loading, planning, ready, removing, done }
    enum SortOrder: String, CaseIterable, Identifiable {
        case size = "크기순"
        case name = "이름순"
        case recent = "최근 사용순"
        var id: String { rawValue }
    }

    @Published var phase: Phase = .list
    @Published var apps: [InstalledApp] = []
    /// App paths whose size measurement is still in flight.
    @Published var sizingPending: Set<String> = []
    @Published var query = ""
    @Published var sortOrder: SortOrder = .size
    @Published var plan: UninstallPlan?
    @Published var selected: Set<String> = []
    @Published var execution: UninstallResult?
    @Published var error: String?

    /// Bumps on every loadApps so a stale sizing pass stops early and late
    /// results can't write into a newer list. Sendable: read from worker threads.
    private final class SizingBuffer: @unchecked Sendable {
        var values: [SizeResult]
        init(count: Int) { values = [SizeResult](repeating: .zero, count: count) }
    }
    private final class SizingGeneration: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() -> Int { lock.withLock { value += 1; return value } }
        func isCurrent(_ generation: Int) -> Bool { lock.withLock { generation == value } }
    }
    private let sizingGeneration = SizingGeneration()

    var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? apps : apps.filter {
            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
        switch sortOrder {
        case .size:
            return base.sorted {
                $0.size.bytes != $1.size.bytes
                    ? $0.size.bytes > $1.size.bytes
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .name:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return base.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }
    }

    var selectableLeftoverPaths: Set<String> {
        guard let plan else { return [] }
        return Set(plan.leftovers.filter { !$0.requiresAdmin }.map(\.path))
    }

    var allLeftoversSelected: Bool {
        let all = selectableLeftoverPaths
        return !all.isEmpty && all.isSubset(of: selected)
    }

    var selectedItems: [LeftoverItem] {
        guard let plan else { return [] }
        return ([plan.bundleItem] + plan.leftovers).filter { selected.contains($0.path) && !$0.requiresAdmin }
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size.bytes } }

    func toggleSelectAllLeftovers() {
        guard let plan else { return }
        if allLeftoversSelected {
            selected = [plan.bundleItem.path]
        } else {
            selected = Set(([plan.bundleItem] + plan.leftovers).filter { !$0.requiresAdmin }.map(\.path))
        }
    }

    func loadApps() {
        phase = .loading
        error = nil
        let token = sizingGeneration.bump()
        Task {
            // discovery only: the list appears first, bundle sizes fill in as measured
            let found = await Task.detached(priority: .userInitiated) { () -> [InstalledApp] in
                guard let deleter = try? AppEnvironment.current.makeDeleter() else { return [] }
                return AppInventory(home: AppEnvironment.current.home)
                    .discover(protection: deleter.policy.protection)
            }.value
            guard sizingGeneration.isCurrent(token) else { return }
            apps = found
            sizingPending = Set(found.map(\.path))
            phase = .list
            let generation = sizingGeneration
            Task.detached(priority: .utility) {
                let deadline = Date().addingTimeInterval(30)
                let measured = SizingBuffer(count: found.count)
                DispatchQueue.concurrentPerform(iterations: found.count) { i in
                    guard generation.isCurrent(token) else { return }
                    measured.values[i] = SizeCalculator.allocatedSize(of: found[i].path, deadline: deadline)
                }
                guard generation.isCurrent(token) else { return }
                let sizesByPath = Dictionary(uniqueKeysWithValues: zip(found.map(\.path), measured.values))
                await MainActor.run {
                    guard generation.isCurrent(token) else { return }
                    for idx in self.apps.indices {
                        if let s = sizesByPath[self.apps[idx].path] {
                            self.apps[idx].size = s
                        }
                    }
                    self.sizingPending.removeAll()
                }
            }
        }
    }

    func select(_ app: InstalledApp) {
        phase = .planning
        plan = nil
        execution = nil
        error = nil
        let all = apps            // reuse the loaded list instead of rescanning
        Task {
            let p = await Task.detached(priority: .userInitiated) { () -> UninstallPlan? in
                guard let engine = try? AppEnvironment.current.makeUninstallEngine() else { return nil }
                var target = app
                if target.size == .zero {
                    target.size = SizeCalculator.allocatedSize(of: target.path)
                }
                let siblings = UninstallEngine.siblings(of: target, in: all)
                return engine.plan(for: target, siblings: siblings, probes: ProbeContext.capture())
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
                let res = try await Task.detached(priority: .userInitiated) {
                    try engine.execute(app: plan.app, items: items, probes: probes)
                }.value
                execution = res
                if !FileStat.exists(plan.app.path) || res.removedCount > 0 {
                    apps.removeAll { $0.path == plan.app.path }
                    sizingPending.remove(plan.app.path)
                }
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
        // reuse the loaded list — sizes already measured keep showing, and any
        // sizing still in flight continues to fill in
        phase = .list
    }
}

struct UninstallView: View {
    @ObservedObject var model: UninstallModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeaderBar(pane: .uninstall) {
                if model.phase == .list {
                    StatusPill(text: "설치된 앱 \(model.apps.count)개", color: .pink, icon: "square.grid.2x2.fill")
                } else if model.phase == .ready, !model.selectableLeftoverPaths.isEmpty {
                    Button(model.allLeftoversSelected ? "잔여물 전체 해제" : "잔여물 전체 선택") {
                        model.toggleSelectAllLeftovers()
                    }
                    .controlSize(.small)
                }
            }
            Divider()
            content
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
        .onAppear { if model.apps.isEmpty && model.phase == .list { model.loadApps() } }
        .confirmationDialog("\"\(model.plan?.app.name ?? "")\"과(와) 선택한 항목을 휴지통으로 이동할까요?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("휴지통으로 이동", role: .destructive) { model.uninstall() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("앱 번들과 \(model.selectedItems.filter { $0.path != model.plan?.bundleItem.path }.count)개 관련 파일(\(bytes(model.selectedBytes)))이 이동됩니다. 이동 전에 안전 검사를 다시 수행합니다.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .list:
            appList
        case .loading:
            loadingState(title: "설치된 앱 목록을 읽고 있습니다…", subtitle: "/Applications 및 사용자 응용 프로그램 폴더를 탐색합니다.")
        case .planning:
            loadingState(title: "관련 잔여물 파일을 탐색하고 있습니다…", subtitle: "~/Library 내 캐시, 설정, 컨테이너를 분석합니다.")
        case .removing:
            loadingState(title: "선택한 항목을 휴지통으로 이동하고 있습니다…", subtitle: "안전 정책 및 프로세스 실행 여부를 최종 확인합니다.")
        case .ready:
            if let plan = model.plan { leftoverList(plan) }
        case .done:
            if let e = model.execution { uninstallSummary(e) }
        }
    }

    private func loadingState(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: app list

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("앱 이름 또는 번들 ID 검색…", text: $model.query)
                        .textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))

                Picker("정렬", selection: $model.sortOrder) {
                    ForEach(UninstallModel.SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))

            Divider()

            List(model.filtered) { app in
                Button { model.select(app) } label: {
                    HStack(spacing: 12) {
                        AppBundleIcon(path: app.path, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(app.name)
                                    .fontWeight(.semibold)
                                if let ver = app.version, !ver.isEmpty {
                                    Text("v\(ver)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                }
                                if app.officialUninstaller != nil {
                                    StatusPill(text: "공식 언인스톨러 필요", color: .orange, icon: "wrench.and.screwdriver.fill")
                                }
                            }
                            Text(app.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let used = lastUsed(app.lastUsed)
                        if !used.isEmpty {
                            StatusPill(text: used, color: .secondary, icon: "clock")
                        }
                        Text(model.sizingPending.contains(app.path)
                             ? "계산 중…" : ByteFormat.string(app.size.bytes, partial: app.size.partial))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(model.sizingPending.contains(app.path) ? Color.secondary : Color.primary)
                            .frame(width: 88, alignment: .trailing)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
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
            HStack(spacing: 14) {
                Button { model.back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("뒤로")

                AppBundleIcon(path: plan.app.path, size: 42)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plan.app.name)
                            .font(.headline)
                        if let ver = plan.app.version, !ver.isEmpty {
                            StatusPill(text: "v\(ver)", color: .secondary)
                        }
                    }
                    Text("\(plan.app.bundleID) · \(plan.app.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("앱 번들 크기")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ByteFormat.string(plan.app.size.bytes, partial: plan.app.size.partial))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            Divider()

            List {
                Section("앱 번들 및 발견된 잔여물 (\(1 + plan.leftovers.count)개)") {
                    leftoverRow(plan.bundleItem, fixed: true)
                    ForEach(plan.leftovers) { item in
                        leftoverRow(item, fixed: false)
                    }
                }
                if !plan.skipped.isEmpty {
                    Section("보호 규칙으로 제외됨 (\(plan.skipped.count)개)") {
                        ForEach(plan.skipped.indices, id: \.self) { i in
                            HStack {
                                Image(systemName: "shield.lefthalf.filled")
                                    .foregroundStyle(.secondary)
                                Text(plan.skipped[i].path)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                StatusPill(text: plan.skipped[i].reason.rawValue, color: .secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func leftoverRow(_ item: LeftoverItem, fixed: Bool) -> some View {
        HStack(spacing: 10) {
            if item.requiresAdmin {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 18)
            } else {
                Toggle(item.path, isOn: Binding(
                    get: { fixed || model.selected.contains(item.path) },
                    set: { isOn in
                        if isOn { model.selected.insert(item.path) } else { model.selected.remove(item.path) }
                    }))
                .labelsHidden()
                .disabled(fixed)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if fixed {
                        StatusPill(text: "앱 번들 (필수)", color: .blue, icon: "app.fill")
                    } else {
                        StatusPill(text: leftoverCategoryLabel(item.path), color: .secondary)
                    }
                    if item.requiresAdmin {
                        StatusPill(text: "관리자 권한 필요 (표시 전용)", color: .orange, icon: "lock.fill")
                    } else if item.sensitive {
                        StatusPill(text: "개인 데이터 포함 가능", color: .pink, icon: "exclamationmark.shield.fill")
                    }
                }
            }
            Spacer()
            Text(ByteFormat.string(item.size.bytes, partial: item.size.partial))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(item.requiresAdmin ? Color.secondary : Color.primary)
        }
        .padding(.vertical, 3)
    }

    private func leftoverCategoryLabel(_ path: String) -> String {
        if path.contains("/Application Support/") { return "Application Support" }
        if path.contains("/Caches/") { return "캐시" }
        if path.contains("/Preferences/") { return "환경설정" }
        if path.contains("/Saved Application State/") { return "저장된 상태" }
        if path.contains("/Containers/") || path.contains("/Group Containers/") { return "컨테이너" }
        if path.contains("/Logs/") { return "로그" }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") { return "백그라운드 에이전트" }
        if path.contains("/PrivilegedHelperTools/") { return "특권 헬퍼 도구" }
        return "관련 데이터"
    }

    // MARK: summary + footer

    private func uninstallSummary(_ result: UninstallResult) -> some View {
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
                        Text("\(bytes(result.removedBytes)) 확보 · 휴지통 이동 완료")
                            .font(.title2.weight(.bold))
                        Text("총 \(result.removedCount)개 항목을 안전하게 휴지통으로 이동했습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            if !result.skipped.isEmpty {
                Section("건너뜀 (\(result.skipped.count)개)") {
                    ForEach(result.skipped.indices, id: \.self) { i in
                        summaryRow(result.skipped[i].path, result.skipped[i].reason, color: .secondary)
                    }
                }
            }
            if !result.failed.isEmpty {
                Section("실패 (\(result.failed.count)개)") {
                    ForEach(result.failed.indices, id: \.self) { i in
                        summaryRow(result.failed[i].path, result.failed[i].message, color: .red)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func summaryRow(_ path: String, _ reason: String, color: Color) -> some View {
        HStack {
            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            StatusPill(text: reason, color: color)
        }
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
                        .foregroundStyle(.pink)
                        .monospacedDigit()
                }
            } else {
                Text("앱과 잔여물은 영구 삭제되지 않고 휴지통으로 안전하게 이동됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .list {
                Button {
                    model.loadApps()
                } label: {
                    Label("다시 스캔", systemImage: "arrow.clockwise")
                }
            }
            if model.phase == .ready {
                Button("목록으로") { model.back() }
                Button {
                    confirming = true
                } label: {
                    Label("휴지통으로 이동…", systemImage: "trash")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(model.selectedItems.isEmpty || model.plan?.app.officialUninstaller != nil)
            }
            if model.phase == .done {
                Button("앱 목록으로 돌아가기") { model.back() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct AppBundleIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        let img = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .applicationBundle)
        Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
