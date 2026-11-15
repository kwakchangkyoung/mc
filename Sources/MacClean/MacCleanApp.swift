import AppKit
import MacCleanCore
import SwiftUI

struct MacCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("맥클린") {
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Pane: String, CaseIterable, Identifiable {
    case dashboard = "대시보드"
    case clean = "정리"
    case settings = "설정"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .clean: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @State private var pane: Pane = .dashboard
    @StateObject private var status = StatusModel()
    @StateObject private var clean = CleanModel()

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
            case .settings: SettingsView()
            }
        }
        .onAppear { status.start() }
    }
}
