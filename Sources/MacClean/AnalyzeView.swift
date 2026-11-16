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
                scanning = false
            } catch {
                guard cancellation === token else { return }
                self.error = "\(t)을(를) 읽을 수 없습니다."
                scanning = false
            }
        }
    }

    func stopScan() {
        cancellation?.cancel()
        scanning = false
    }

    /// Show a cached subtree instantly — same shape as a fresh scan of that directory.
    private func apply(_ target: AnalyzeNode) {
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
        guard entry.isDir else { return }
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
        guard let target = selection else { return }
        let expected = selectedIdentity
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
            header
            Divider()
            content
            Divider()
            footer.padding(14)
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

    // MARK: header (back + breadcrumb)

    private var crumbs: [(name: String, path: String)] {
        var out = [(FileManager.default.displayName(atPath: "/"), "/")]
        var p = ""
        for c in model.path.split(separator: "/") {
            p += "/" + c
            out.append((String(c), p))
        }
        return out
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Text("›").foregroundStyle(.tertiary) }
                        Button(c.name) { model.navigate(to: c.path) }
                            .buttonStyle(.plain)
                            .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                            .disabled(i == crumbs.count - 1)
                    }
                }
            }
        }
        .padding(10)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if model.scanning && model.result == nil {
            VStack(spacing: 10) {
                ProgressView("스캔 중…")
                Button("중단") { model.stopScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.result {
            VStack(spacing: 0) {
                Picker("", selection: $model.tab) {
                    Text("항목").tag(AnalyzeModel.Tab.entries)
                    Text("큰 파일").tag(AnalyzeModel.Tab.largeFiles)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .padding(.vertical, 6)
                if model.tab == .entries {
                    entryList(result)
                } else {
                    largeFileList(result)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "internaldrive").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(model.error ?? "폴더를 열 수 없습니다").foregroundStyle(.secondary)
                Button("다시 시도") { model.scan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func entryList(_ result: AnalyzeResult) -> some View {
        List(selection: $model.selection) {
            ForEach(result.entries) { entry in
                AnalyzeEntryRow(entry: entry, maxSize: result.entries.first?.size ?? 0,
                                total: result.totalSize)
                    .tag(entry.path)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.drill(entry) })
                    .contextMenu {
                        if entry.isDir { Button("열기") { model.drill(entry) } }
                        Button("Finder에서 보기") { model.reveal(entry.path) }
                        Divider()
                        Button("휴지통으로 이동…", role: .destructive) {
                            model.selection = entry.path
                            confirmingTrash = true
                        }
                    }
            }
        }
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
            ForEach(result.largeFiles) { file in
                HStack {
                    Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 18)
                    Text(file.name).lineLimit(1)
                    Text(file.path).font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormat.string(file.size)).monospacedDigit()
                }
                .tag(file.path)
                .contextMenu {
                    Button("Finder에서 보기") { model.reveal(file.path) }
                    Divider()
                    Button("휴지통으로 이동…", role: .destructive) {
                        model.selection = file.path
                        confirmingTrash = true
                    }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("스캔 중…")
            } else if let r = model.result {
                Text("\(r.entries.count)개 항목 · \(ByteFormat.string(r.totalSize))"
                     + (r.partial ? " (일부 읽기 실패)" : ""))
                    .monospacedDigit()
            }
            Spacer()
            Button("새로고침") { model.scan() }
                .disabled(model.scanning)
            Button("Finder에서 보기") {
                if let sel = model.selection { model.reveal(sel) }
            }
            .disabled(model.selection == nil)
            Button("휴지통으로 이동…") { confirmingTrash = true }
                .disabled(model.selection == nil || model.scanning)
        }
    }
}

struct AnalyzeEntryRow: View {
    let entry: AnalyzeEntry
    let maxSize: Int64
    let total: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDir ? "folder" : "doc")
                .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(entry.name + (entry.isSymlink ? " →" : ""))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            bar
            Text(percent)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(ByteFormat.string(entry.size, partial: entry.partial))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Text(entry.isDir && !entry.isSymlink ? "\(entry.itemCount)개" : "")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 2)
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
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(entry.isDir ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.5))
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * fraction))
            }
        }
        .frame(width: 110, height: 10)
    }
}
