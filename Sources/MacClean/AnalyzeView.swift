import AppKit
import MacCleanCore
import SwiftUI

@MainActor
final class AnalyzeModel: ObservableObject {
    enum Tab { case treemap, entries, largeFiles }

    @Published var path = "/"
    @Published var canGoBack = false
    @Published var result: AnalyzeResult?
    @Published var scanning = false
    @Published var error: String?
    @Published var trashError: String?
    @Published var selection: String?
    @Published var tab: Tab = .treemap

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
        drillPath(entry.path)
    }

    func drillPath(_ targetPath: String) {
        guard !scanning, FileStat.isDirectory(targetPath) else { return }
        if let child = findDescendantNode(path: targetPath, in: node),
           !child.isOtherDevice, child.collected {
            backStack.append((path, node))
            canGoBack = true
            apply(child)
        } else {
            scan(targetPath, push: true)
        }
    }

    private func findDescendantNode(path targetPath: String, in rootNode: AnalyzeNode?) -> AnalyzeNode? {
        guard let rootNode else { return nil }
        for d in rootNode.dirs {
            if d.path == targetPath { return d }
            if targetPath.hasPrefix(d.path + "/"),
               let found = findDescendantNode(path: targetPath, in: d) {
                return found
            }
        }
        return nil
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
                // Invalidate cached ancestor trees so navigating back reflects the freed space
                backStack = backStack.map { ($0.path, nil) }
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
                    Picker("보기 방식", selection: $model.tab) {
                        Text("트리맵 · 목록").tag(AnalyzeModel.Tab.treemap)
                        Text("목록만").tag(AnalyzeModel.Tab.entries)
                        Text("대용량 파일").tag(AnalyzeModel.Tab.largeFiles)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

                    Button {
                        model.chooseFolder()
                    } label: {
                        Label("폴더 선택…", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(model.scanning)
                }
            }
            Divider()
            breadcrumbAndStatsBar
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

    // MARK: breadcrumb + summary stats bar

    private var crumbs: [(name: String, path: String)] {
        var out = [(FileManager.default.displayName(atPath: "/"), "/")]
        var p = ""
        for c in model.path.split(separator: "/") {
            p += "/" + c
            out.append((String(c), p))
        }
        return out
    }

    private var breadcrumbAndStatsBar: some View {
        HStack(spacing: 10) {
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

            Spacer(minLength: 8)

            if let r = model.result {
                let folderCount = r.entries.filter(\.isDir).count
                HStack(spacing: 16) {
                    statMetric(label: "스캔 용량", value: ByteFormat.string(r.totalSize))
                    statMetric(label: "전체 파일", value: "\(r.totalFiles.formatted())개")
                    statMetric(label: "하위 폴더", value: "\(folderCount)개")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func statMetric(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
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
            switch model.tab {
            case .treemap:
                VStack(spacing: 0) {
                    if !result.entries.isEmpty {
                        DiskTreemapView(
                            result: result,
                            selection: $model.selection,
                            onDrill: { path in model.drillPath(path) },
                            onReveal: { path in model.reveal(path) },
                            onTrashTopLevel: { topPath in
                                model.selection = topPath
                                confirmingTrash = true
                            }
                        )
                        .frame(minHeight: 235, idealHeight: 270, maxHeight: 310)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                        Divider()
                    }
                    entryList(result)
                }
            case .entries:
                VStack(spacing: 0) {
                    if !result.entries.isEmpty {
                        StorageBreakdownBar(result: result)
                        Divider()
                    }
                    entryList(result)
                }
            case .largeFiles:
                largeFileList(result)
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

// MARK: - Nested Squarified Treemap View

struct DiskTreemapView: View {
    let result: AnalyzeResult
    @Binding var selection: String?
    let onDrill: (String) -> Void
    let onReveal: (String) -> Void
    let onTrashTopLevel: (String) -> Void

    @State private var hoverLocation: CGPoint?
    @State private var lastClickedPath: String?
    @State private var lastClickTime: Date = .distantPast

    private var rootName: String {
        let name = (result.root as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? FileManager.default.displayName(atPath: "/") : name
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4)
            let cells = TreemapLayout.compute(result: result, in: bounds, maxDepth: 2)
            let hovered = hoverLocation.flatMap { TreemapLayout.hitTest(cells, at: $0) }

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for cell in cells {
                        drawCell(cell, in: &context, hoveredPath: hovered?.path)
                    }
                    // Draw selection highlight on top of everything
                    if let sel = selection,
                       let selCell = cells.first(where: { $0.path == sel || $0.topLevelPath == sel }) {
                        let highlightRect = selCell.rect.insetBy(dx: 0.75, dy: 0.75)
                        let path = Path(roundedRect: highlightRect, cornerRadius: 5)
                        context.stroke(
                            path,
                            with: .color(Color(red: 0.25, green: 0.70, blue: 1.0)),
                            lineWidth: 2.2
                        )
                    }
                    // Draw hover outline
                    if let hov = hovered {
                        let hRect = hov.rect.insetBy(dx: 0.75, dy: 0.75)
                        let path = Path(roundedRect: hRect, cornerRadius: 4)
                        context.stroke(
                            path,
                            with: .color(Color.white.opacity(0.9)),
                            lineWidth: 1.5
                        )
                    }
                }
                .background(
                    Color(red: 0.08, green: 0.12, blue: 0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let pt):
                        hoverLocation = pt
                    case .ended:
                        hoverLocation = nil
                    }
                }
                .gesture(
                    SpatialTapGesture(count: 1).onEnded { event in
                        guard let hit = TreemapLayout.hitTest(cells, at: event.location) else { return }
                        let now = Date()
                        if lastClickedPath == hit.path, now.timeIntervalSince(lastClickTime) < 0.35 {
                            // Double-click → drill into the clicked directory (or its top-level folder)
                            let drillTarget = hit.isDir ? hit.path : hit.topLevelPath
                            onDrill(drillTarget)
                            lastClickedPath = nil
                        } else {
                            selection = hit.topLevelPath
                            lastClickedPath = hit.path
                            lastClickTime = now
                        }
                    }
                )
                .contextMenu {
                    if let hov = hovered {
                        if hov.isDir {
                            Button("“\(hov.name)” 폴더 열기") { onDrill(hov.path) }
                        } else if hov.topLevelPath != hov.path {
                            Button("상위 폴더 열기") { onDrill(hov.topLevelPath) }
                        }
                        Button("Finder에서 보기") { onReveal(hov.path) }
                        Divider()
                        Button("휴지통으로 이동…", role: .destructive) {
                            onTrashTopLevel(hov.topLevelPath)
                        }
                    } else if let sel = selection {
                        Button("Finder에서 보기") { onReveal(sel) }
                        Divider()
                        Button("휴지통으로 이동…", role: .destructive) {
                            onTrashTopLevel(sel)
                        }
                    }
                }

                if let hov = hovered, let pt = hoverLocation {
                    TreemapTooltipCard(
                        cell: hov,
                        rootName: rootName,
                        rootTotalSize: result.totalSize
                    )
                    .offset(tooltipOffset(for: pt, in: geo.size))
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func tooltipOffset(for cursor: CGPoint, in size: CGSize) -> CGSize {
        let cardWidth: CGFloat = 240
        let cardHeight: CGFloat = 78
        var x = cursor.x + 14
        var y = cursor.y + 14
        if x + cardWidth > size.width - 8 {
            x = max(8, cursor.x - cardWidth - 12)
        }
        if y + cardHeight > size.height - 8 {
            y = max(8, cursor.y - cardHeight - 12)
        }
        return CGSize(width: x, height: y)
    }

    // MARK: - Canvas cell drawing

    private func drawCell(
        _ cell: TreemapCell,
        in context: inout GraphicsContext,
        hoveredPath: String?
    ) {
        let gap: CGFloat = cell.depth == 0 ? 1.5 : 1.0
        let box = cell.rect.insetBy(dx: gap, dy: gap)
        guard box.width >= 2, box.height >= 2 else { return }

        let radius: CGFloat = cell.depth == 0 ? 5 : (cell.depth == 1 ? 3.5 : 2.5)
        let shape = Path(roundedRect: box, cornerRadius: radius)
        let isHovered = cell.path == hoveredPath

        if !cell.children.isEmpty {
            // Container directory frame (emerald / jade header + darker interior well)
            let frameColor = containerColor(depth: cell.depth, group: cell.groupIndex, hovered: isHovered)
            context.fill(shape, with: .color(frameColor))
            context.stroke(shape, with: .color(Color.white.opacity(0.18)), lineWidth: 0.75)

            // Header title
            let headerH: CGFloat = cell.depth == 0 ? 18 : 15
            if box.width >= 36, box.height >= headerH {
                let titleRect = CGRect(
                    x: box.minX + 6,
                    y: box.minY + 1,
                    width: max(0, box.width - 12),
                    height: headerH - 1
                )
                var clipped = context
                clipped.clip(to: Path(titleRect))
                let fontSize: CGFloat = cell.depth == 0 ? 11.5 : 10.5
                let label = Text(cell.name)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white.opacity(0.95))
                clipped.draw(label, at: CGPoint(x: titleRect.minX, y: titleRect.midY), anchor: .leading)
            }

            // Inner well background behind child tiles
            let pad: CGFloat = cell.depth == 0 ? 2.5 : 1.5
            let wellRect = CGRect(
                x: box.minX + pad,
                y: box.minY + headerH - 1,
                width: max(0, box.width - pad * 2),
                height: max(0, box.height - headerH - pad + 1)
            )
            if wellRect.width > 4, wellRect.height > 4 {
                let wellPath = Path(roundedRect: wellRect, cornerRadius: max(2, radius - 1.5))
                context.fill(wellPath, with: .color(Color(red: 0.08, green: 0.16, blue: 0.15).opacity(0.65)))
            }

            for child in cell.children {
                drawCell(child, in: &context, hoveredPath: hoveredPath)
            }
        } else {
            // Leaf block (file or un-subdivided directory)
            let fill = leafColor(isDir: cell.isDir, depth: cell.depth, group: cell.groupIndex, hovered: isHovered)
            context.fill(shape, with: .color(fill))
            context.stroke(shape, with: .color(Color.white.opacity(0.16)), lineWidth: 0.75)

            if box.width >= 38, box.height >= 17 {
                let textRect = box.insetBy(dx: 5, dy: 3)
                var clipped = context
                clipped.clip(to: Path(textRect))

                let nameText = Text(cell.name)
                    .font(.system(size: cell.depth == 0 ? 11.5 : 10.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                clipped.draw(nameText, at: CGPoint(x: textRect.minX, y: textRect.minY + 1), anchor: .topLeading)

                if box.width >= 54, box.height >= 33 {
                    let sizeText = Text(ByteFormat.string(cell.size))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                    clipped.draw(
                        sizeText,
                        at: CGPoint(x: textRect.minX, y: textRect.minY + 15),
                        anchor: .topLeading
                    )
                }
            }
        }
    }

    private func containerColor(depth: Int, group: Int, hovered: Bool) -> Color {
        let boost = hovered ? 0.06 : 0.0
        switch depth {
        case 0:
            // Top-level emerald / jade containers
            let variants: [(Double, Double, Double)] = [
                (0.22, 0.62, 0.45),
                (0.20, 0.58, 0.48),
                (0.24, 0.60, 0.42),
                (0.19, 0.55, 0.46),
            ]
            let c = variants[group % variants.count]
            return Color(red: c.0 + boost, green: c.1 + boost, blue: c.2 + boost)
        default:
            return Color(red: 0.18 + boost, green: 0.50 + boost, blue: 0.42 + boost)
        }
    }

    private func leafColor(isDir: Bool, depth: Int, group: Int, hovered: Bool) -> Color {
        let boost = hovered ? 0.08 : 0.0
        if isDir {
            // Subfolder leaf: rich jade green
            let variants: [(Double, Double, Double)] = [
                (0.23, 0.57, 0.44),
                (0.20, 0.52, 0.46),
                (0.25, 0.55, 0.40),
                (0.19, 0.49, 0.43),
            ]
            let c = variants[(group + depth) % variants.count]
            return Color(red: c.0 + boost, green: c.1 + boost, blue: c.2 + boost)
        } else {
            // File leaf: cool ocean teal / slate blue (distinct from folder jade)
            let variants: [(Double, Double, Double)] = [
                (0.24, 0.48, 0.56),
                (0.27, 0.44, 0.54),
                (0.22, 0.51, 0.53),
                (0.31, 0.41, 0.49),
            ]
            let c = variants[(group + depth) % variants.count]
            return Color(red: c.0 + boost, green: c.1 + boost, blue: c.2 + boost)
        }
    }
}

struct TreemapTooltipCard: View {
    let cell: TreemapCell
    let rootName: String
    let rootTotalSize: Int64

    private var sharePercent: String {
        guard rootTotalSize > 0 else { return "0%" }
        let p = Double(cell.size) * 100.0 / Double(rootTotalSize)
        return p < 0.1 ? "<0.1%" : String(format: "%.1f%%", p)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: cell.isDir ? "folder.fill" : "doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.88, blue: 0.72))
                Text(cell.name)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Text("\(ByteFormat.string(cell.size)) · \(rootName)의 \(sharePercent)")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()

            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                Text(cell.parentName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                if cell.isDir {
                    Text("· 파일 \(cell.itemCount.formatted())개")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(red: 0.11, green: 0.22, blue: 0.20).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.38), radius: 10, x: 0, y: 4)
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
