import AppKit
import MacCleanCore
import SwiftUI

struct MacCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // one window only — each window owns its models and concurrent
        // destructive runs must not be possible
        Window("맥클린", id: "main") {
            RootView()
                .frame(minWidth: 920, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM executable there is no bundle Info.plist; make it a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // …and it has no bundle icon: use AppIcon.icns from the bundle or next to
        // the executable when one is there; skip silently otherwise
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let icns = Bundle.main.path(forResource: "AppIcon", ofType: "icns")
            ?? exeDir?.appending(path: "../Resources/AppIcon.icns").path
            ?? exeDir?.appending(path: "AppIcon.icns").path
            ?? exeDir?.appending(path: "Resources/AppIcon.icns").path
            ?? "Resources/AppIcon.icns"
        if let icon = NSImage(contentsOfFile: icns) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum PaneSection: String, CaseIterable, Identifiable {
    case monitor = "모니터링"
    case manage = "정리 및 관리"
    case system = "시스템"

    var id: String { rawValue }
}

enum Pane: String, CaseIterable, Identifiable {
    case dashboard = "대시보드"
    case clean = "정리"
    case analyze = "디스크 분석"
    case uninstall = "앱 삭제"
    case optimize = "최적화"
    case settings = "설정"

    var id: String { rawValue }

    var section: PaneSection {
        switch self {
        case .dashboard: return .monitor
        case .clean, .analyze, .uninstall: return .manage
        case .optimize, .settings: return .system
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .clean: return "sparkles"
        case .analyze: return "internaldrive.fill"
        case .uninstall: return "trash.fill"
        case .optimize: return "bolt.shield.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: return .blue
        case .clean: return .teal
        case .analyze: return .indigo
        case .uninstall: return .pink
        case .optimize: return .orange
        case .settings: return .secondary
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: return "실시간 자원 사용량과 시스템 건강 상태"
        case .clean: return "사용자 캐시, 로그, 개발 도구 캐시 정리"
        case .analyze: return "폴더별 공간 점유 현황과 대용량 파일 탐색"
        case .uninstall: return "앱 번들과 숨은 라이브러리 잔여물 제거"
        case .optimize: return "시스템 진단 및 유지보수 작업 실행"
        case .settings: return "권한, 화이트리스트, 작업 로그 관리"
        }
    }
}

struct RootView: View {
    @State private var pane: Pane = .dashboard
    @StateObject private var status = StatusModel()
    @StateObject private var clean = CleanModel()
    @StateObject private var analyze = AnalyzeModel()
    @StateObject private var uninstall = UninstallModel()
    @StateObject private var optimize = OptimizeModel()
    @StateObject private var updater = UpdateModel()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarBrandHeader
                Divider().opacity(0.5)
                List(selection: $pane) {
                    ForEach(PaneSection.allCases) { sec in
                        Section(sec.rawValue) {
                            ForEach(Pane.allCases.filter { $0.section == sec }) { p in
                                SidebarRow(
                                    pane: p,
                                    isSelected: pane == p,
                                    hasBadge: p == .settings && updater.availableRelease != nil
                                )
                                .tag(p)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 195, ideal: 210, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if updater.shouldShowBanner, let release = updater.availableRelease, pane != .settings {
                    UpdateBannerView(updater: updater, release: release)
                    Divider()
                }
                switch pane {
                case .dashboard: DashboardView(model: status)
                case .clean: CleanView(model: clean)
                case .analyze: AnalyzeView(model: analyze)
                case .uninstall: UninstallView(model: uninstall)
                case .optimize: OptimizeView(model: optimize)
                case .settings: SettingsView(updater: updater)
                }
            }
        }
        .onAppear { updater.checkOnLaunchIfNeeded() }
    }

    private var sidebarBrandHeader: some View {
        HStack(spacing: 10) {
            AppLogoView(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("맥클린")
                    .font(.system(size: 14, weight: .bold))
                Text("MacClean")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SidebarRow: View {
    let pane: Pane
    let isSelected: Bool
    var hasBadge: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : pane.tint.opacity(0.14))
                    .frame(width: 24, height: 24)
                Image(systemName: pane.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : pane.tint)
            }
            Text(pane.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            Spacer(minLength: 0)
            if hasBadge {
                Circle()
                    .fill(isSelected ? Color.white : Color.blue)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shared UI Components

struct PaneHeaderBar<Trailing: View>: View {
    let pane: Pane
    @ViewBuilder var trailing: () -> Trailing

    init(pane: Pane, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.pane = pane
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(pane.tint.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: pane.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(pane.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.rawValue)
                    .font(.title3.weight(.bold))
                Text(pane.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct AppLogoView: View {
    let size: CGFloat

    private var iconImage: NSImage? {
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let paths: [String?] = [
            Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
            Bundle.main.path(forResource: "AppIcon-preview", ofType: "png"),
            exeDir?.appending(path: "../Resources/AppIcon.icns").path,
            exeDir?.appending(path: "../Resources/AppIcon-preview.png").path,
            exeDir?.appending(path: "AppIcon.icns").path,
            exeDir?.appending(path: "Resources/AppIcon.icns").path,
            exeDir?.appending(path: "Resources/AppIcon-preview.png").path,
            "Resources/AppIcon.icns",
            "Resources/AppIcon-preview.png",
            "/Volumes/m2ssd/bak_workspace/mc/Resources/AppIcon.icns",
            "/Volumes/m2ssd/bak_workspace/mc/Resources/AppIcon-preview.png",
            "/Volumes/m2ssd/bak_workspace/mc/.worktrees/ui-redesign/Resources/AppIcon.icns",
            "/Volumes/m2ssd/bak_workspace/mc/.worktrees/ui-redesign/Resources/AppIcon-preview.png",
        ]
        for p in paths.compactMap({ $0 }) {
            if let img = NSImage(contentsOfFile: p), img.isValid {
                return img
            }
        }
        if let icon = NSImage(named: "AppIcon"), icon.isValid {
            return icon
        }
        return nil
    }

    var body: some View {
        if let iconImage {
            Image(nsImage: iconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.30, green: 0.74, blue: 0.98), Color(red: 0.16, green: 0.41, blue: 0.90)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Image(systemName: "sparkles")
                    .foregroundStyle(.white)
                    .font(.system(size: size * 0.45))
            }
            .frame(width: size, height: size)
        }
    }
}
