import AppKit
import MacCleanCore
import SwiftUI

@MainActor
final class AnalyzeModel: ObservableObject {
    enum Tab { case entries, largeFiles }

    @Published var path = AppEnvironment.current.home
    @Published var canGoBack = false
    @Published var result: AnalyzeResult?
    @Published var scanning = false
    @Published var error: String?
    @Published var trashError: String?
    @Published var selection: String?
    @Published var tab: Tab = .entries

    private var cancellation: ScanCancellation?
    /// Aggregated scan tree backing the displayed result — makes drill-in/back instant.
    private var node: AnalyzeNode?
    /// States to return to, latest last; a nil node means that level needs a rescan.
    private var backStack: [(path: String, node: AnalyzeNode?)] = []

    var selectedEntry: AnalyzeEntry? { result?.entries.first { $0.path == selection } }
    var selectedName: String { ((selection ?? "") as NSString).lastPathComponent }
    var selectedSize: Int64 {
        selectedEntry?.size ?? result?.largeFiles.first { $0.path == selection }?.size ?? 0
    }
    /// Scan-time dev:inode of the selected item (entries and large files both carry one).
    var selectedIdentity: PathIdentity? {
        selectedEntry?.identity ?? result?.largeFiles.first { $0.path == selection }?.identity
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "폴더 스캔"
        if panel.runModal() == .OK, let url = panel.url {
            scan(url.path, push: true)
        }
    }

    func scan(_ target: String? = nil, push: Bool = false) {
        let t = target ?? path
        if push && t != path { backStack.append((path, node)) }
        canGoBack = !backStack.isEmpty
        cancellation?.cancel()
        let token = ScanCancellation()
        cancellation = token
        path = t
        selection = nil
        scanning = true
        error = nil
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) {
                    try DiskScanner().scan(t, cancellation: token, keepTree: true)
                }.value
                guard cancellation === token, !r.cancelled else { return }
                result = r
                node = r.tree
                // the list shown during the scan may have let the user select an
                // entry that no longer exists — a stale path has no identity to recheck
                if let sel = selection,
                   !r.entries.contains(where: { $0.path == sel }),
                   !r.largeFiles.contains(where: { $0.path == sel }) {
                    selection = nil
                }
                scanning = false
            } catch {
                guard cancellation === token else { return }
                result = nil
                node = nil
                self.error = "\(t)을(를) 읽을 수 없습니다."
                scanning = false
            }
        }
    }

    func stopScan() {
        cancellation?.cancel()
        error = "스캔을 중지했습니다"
        scanning = false
    }

    /// Show a cached subtree instantly — same shape as a fresh scan of that directory.
    private func apply(_ target: AnalyzeNode) {
        // a scan still in flight would later overwrite this view — kill it first
        cancellation?.cancel()
        cancellation = nil
        path = target.path
        node = target
        result = target.asResult()
        selection = nil
        scanning = false
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        canGoBack = !backStack.isEmpty
        if let n = prev.node { apply(n) } else { scan(prev.path) }
    }

    func drill(_ entry: AnalyzeEntry) {
        guard entry.isDir, !scanning else { return }
        // symlink targets, other volumes and folded dirs need a fresh walk: rescan
        if let child = node?.dirs.first(where: { $0.path == entry.path }),
           !child.isOtherDevice, child.collected {
            backStack.append((path, node))
            canGoBack = true
            apply(child)
        } else {
            scan(entry.path, push: true)
        }
    }

    func navigate(to crumb: String) {
        guard crumb != path else { return }
        while let last = backStack.popLast() {
            if last.path == crumb {
                canGoBack = !backStack.isEmpty
                if let n = last.node { apply(n) } else { scan(last.path) }
                return
            }
        }
        scan(crumb, push: true)
    }

    func reveal(_ target: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    func trashSelected() {
        // no scan-time identity → nothing to recheck before trashing, so refuse
        guard let target = selection, let expected = selectedIdentity else { return }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> DeleteOutcome in
                do {
                    let deleter = try AppEnvironment.current.makeDeleter()
                    return deleter.trash(target, expected: expected, probes: ProbeContext.capture())
                } catch {
                    return .failed("화이트리스트 파일을 읽을 수 없습니다: \(error)")
                }
            }.value
            switch outcome {
            case .removed, .missing:
                scan()
            case .skipped(let reason):
                trashError = "이동할 수 없는 항목입니다: \(reason.rawValue)"
            case .failed(let message):
                trashError = message
            case .wouldRemove:
                break
            }
        }
    }
}

struct AnalyzeView: View {
    @ObservedObject var model: AnalyzeModel
    @State private var confirmingTrash = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeaderBar(pane: .analyze) {
                HStack(spacing: 10) {
                    Picker("", selection: $model.tab) {
                        Text("폴더 · 항목").tag(AnalyzeModel.Tab.entries)
                        Text("대용량 파일").tag(AnalyzeModel.Tab.largeFiles)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)

                    Button {
                        model.chooseFolder()
                    } label: {
                        Label("폴더 선택…", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.small)
                    .disabled(model.scanning)
                }
            }
            Divider()
            breadcrumbBar
            Divider()
            content
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
        .onAppear { if model.result == nil && !model.scanning { model.scan() } }
        .confirmationDialog("\"\(model.selectedName)\"을(를) 휴지통으로 이동할까요?",
                            isPresented: $confirmingTrash, titleVisibility: .visible) {
            Button("휴지통으로 이동", role: .destructive) { model.trashSelected() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("크기: \(ByteFormat.string(model.selectedSize)). 이동 전에 안전 검사를 수행합니다.")
        }
        .alert("휴지통으로 이동할 수 없습니다", isPresented: hasTrashError) {
            Button("확인") { model.trashError = nil }
        } message: {
            Text(model.trashError ?? "")
        }
    }

    private var hasTrashError: Binding<Bool> {
        Binding(get: { model.trashError != nil }, set: { if !$0 { model.trashError = nil } })
    }

    // MARK: breadcrumb bar

    private var crumbs: [(name: String, path: String)] {
        var out = [(FileManager.default.displayName(atPath: "/"), "/")]
        var p = ""
        for c in model.path.split(separator: "/") {
            p += "/" + c
            out.append((String(c), p))
        }
        return out
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("뒤로")
            .disabled(!model.canGoBack)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                        let isLast = i == crumbs.count - 1
                        if i > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            model.navigate(to: c.path)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: i == 0 ? "internaldrive.fill" : "folder.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isLast ? Color.indigo : Color.secondary)
                                Text(c.name)
                                    .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                                    .foregroundStyle(isLast ? Color.primary : Color.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                isLast ? Color.indigo.opacity(0.11) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isLast)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if model.scanning && model.result == nil {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("디스크 공간을 분석하고 있습니다…")
                    .font(.headline)
                Text(model.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button("스캔 중단") { model.stopScan() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.result {
            VStack(spacing: 0) {
                if !result.entries.isEmpty {
                    StorageBreakdownBar(result: result)
                    Divider()
                }
                if model.tab == .entries {
                    entryList(result)
                } else {
                    largeFileList(result)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "internaldrive.trianglebadge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(model.error ?? "폴더를 열 수 없습니다")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button("다시 시도") { model.scan() }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func entryList(_ result: AnalyzeResult) -> some View {
        List(selection: $model.selection) {
            ForEach(Array(result.entries.enumerated()), id: \.element.id) { idx, entry in
                AnalyzeEntryRow(
                    entry: entry,
                    rank: idx,
                    maxSize: result.entries.first?.size ?? 0,
                    total: result.totalSize
                )
                .tag(entry.path)
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.drill(entry) })
                .contextMenu {
                    if entry.isDir { Button("하위 폴더 열기") { model.drill(entry) } }
                    Button("Finder에서 보기") { model.reveal(entry.path) }
                    Divider()
                    Button("휴지통으로 이동…", role: .destructive) {
                        model.selection = entry.path
                        confirmingTrash = true
                    }
                    .disabled(model.scanning)
                }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            if let sel = model.selectedEntry, sel.isDir {
                model.drill(sel)
                return .handled
            }
            return .ignored
        }
    }

    private func largeFileList(_ result: AnalyzeResult) -> some View {
        List(selection: $model.selection) {
            if result.largeFiles.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "doc.magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("1MB 이상의 대용량 파일이 없습니다")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 40)
                    Spacer()
                }
            } else {
                ForEach(result.largeFiles) { file in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.indigo.opacity(0.12))
                                .frame(width: 26, height: 26)
                            Image(systemName: "doc.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.indigo)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(file.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteFormat.string(file.size))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                    .tag(file.path)
                    .contextMenu {
                        Button("Finder에서 보기") { model.reveal(file.path) }
                        Divider()
                        Button("휴지통으로 이동…", role: .destructive) {
                            model.selection = file.path
                            confirmingTrash = true
                        }
                        .disabled(model.scanning)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("스캔 중…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let r = model.result {
                HStack(spacing: 8) {
                    Text("\(r.entries.count)개 항목")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("총 \(ByteFormat.string(r.totalSize))")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.indigo)
                        .monospacedDigit()
                    if r.partial {
                        StatusPill(text: "일부 권한 제한", color: .orange, icon: "lock.fill")
                    }
                }
            }
            Spacer()
            Button {
                model.scan()
            } label: {
                Label("새로고침", systemImage: "arrow.clockwise")
            }
            .disabled(model.scanning)

            Button {
                if let sel = model.selection { model.reveal(sel) }
            } label: {
                Label("Finder에서 보기", systemImage: "folder")
            }
            .disabled(model.selection == nil)

            Button {
                confirmingTrash = true
            } label: {
                Label("휴지통으로 이동…", systemImage: "trash")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(model.selection == nil || model.scanning)
        }
    }
}

struct StorageBreakdownBar: View {
    let result: AnalyzeResult

    static let palette: [Color] = [.indigo, .blue, .teal, .cyan, .purple]

    var body: some View {
        let top = Array(result.entries.prefix(5))
        let total = max(result.totalSize, 1)
        let topSum = top.reduce(Int64(0)) { $0 + $1.size }
        let otherBytes = max(result.totalSize - topSum, 0)

        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, item in
                        let w = max(4, geo.size.width * CGFloat(item.size) / CGFloat(total))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Self.palette[i % Self.palette.count])
                            .frame(width: w)
                    }
                    if otherBytes > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.25))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())

            HStack(spacing: 14) {
                ForEach(Array(top.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Self.palette[i % Self.palette.count])
                            .frame(width: 8, height: 8)
                        Text(item.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(ByteFormat.string(item.size))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if otherBytes > 0 {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text("기타")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteFormat.string(otherBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

struct AnalyzeEntryRow: View {
    let entry: AnalyzeEntry
    let rank: Int
    let maxSize: Int64
    let total: Int64

    private var barColor: Color {
        if !entry.isDir { return .secondary }
        let palette = StorageBreakdownBar.palette
        return rank < palette.count ? palette[rank] : .indigo.opacity(0.75)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(entry.isDir ? barColor.opacity(0.14) : Color.secondary.opacity(0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(entry.isDir ? barColor : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isSymlink {
                        StatusPill(text: "심볼릭 링크", color: .secondary, icon: "arrow.turn.up.right")
                    }
                }
                if entry.isDir && !entry.isSymlink {
                    Text("파일 \(entry.itemCount.formatted())개")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            bar
            Text(percent)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            Text(ByteFormat.string(entry.size, partial: entry.partial))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var percent: String {
        guard total > 0 else { return "" }
        let p = Double(entry.size) * 100 / Double(total)
        return p < 1 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
    }

    private var bar: some View {
        GeometryReader { geo in
            let fraction = maxSize > 0 ? CGFloat(entry.size) / CGFloat(maxSize) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(barColor.opacity(0.85))
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
            }
        }
        .frame(width: 120, height: 8)
    }
}
