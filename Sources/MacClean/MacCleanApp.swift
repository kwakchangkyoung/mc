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
                .frame(minWidth: 860, minHeight: 600)
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
        if let icns, let icon = NSImage(contentsOfFile: icns) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Pane: String, CaseIterable, Identifiable {
    case dashboard = "대시보드"
    case clean = "정리"
    case analyze = "디스크 분석"
    case uninstall = "앱 삭제"
    case optimize = "최적화"
    case settings = "설정"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .clean: return "sparkles"
        case .analyze: return "internaldrive"
        case .uninstall: return "trash"
        case .optimize: return "speedometer"
        case .settings: return "gearshape"
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

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch pane {
            case .dashboard: DashboardView(model: status)
            case .clean: CleanView(model: clean)
            case .analyze: AnalyzeView(model: analyze)
            case .uninstall: UninstallView(model: uninstall)
            case .optimize: OptimizeView(model: optimize)
            case .settings: SettingsView()
            }
        }
    }
}
