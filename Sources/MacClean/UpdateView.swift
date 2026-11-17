import AppKit
import MacCleanCore
import SwiftUI

@MainActor
final class UpdateModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(SemanticVersion)
        case available(ReleaseInfo)
        case installing(String)
        case failed(String)
    }

    @AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = true
    @Published var state: State = .idle
    @Published var dismissedTag: String?
    @Published var showingReleaseNotes = false
    private var didCheckOnLaunch = false

    var currentVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.2.2"
    }

    var currentVersion: SemanticVersion {
        SemanticVersion(parsing: currentVersionString) ?? SemanticVersion(0, 2, 2)
    }

    var availableRelease: ReleaseInfo? {
        if case .available(let info) = state { return info }
        return nil
    }

    var shouldShowBanner: Bool {
        guard let rel = availableRelease else { return false }
        return dismissedTag != rel.tagName
    }

    func checkOnLaunchIfNeeded() {
        guard !didCheckOnLaunch else { return }
        didCheckOnLaunch = true
        guard autoCheckUpdates else { return }
        checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool = false) {
        if case .installing = state { return }
        if !silent { state = .checking }
        let current = currentVersion
        Task {
            do {
                let latest = try await ReleaseUpdater.fetchLatestRelease()
                if latest.version > current {
                    dismissedTag = nil
                    state = .available(latest)
                } else {
                    state = .upToDate(current)
                }
            } catch {
                if !silent {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func install(_ release: ReleaseInfo) {
        state = .installing("업데이트 준비 중…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let stagedAppURL = try await ReleaseUpdater.downloadAndPrepareUpdate(
                    release: release,
                    currentBundleURL: Bundle.main.bundleURL,
                    onStatus: { [weak self] message in
                        Task { @MainActor in
                            self?.state = .installing(message)
                        }
                    }
                )
                self.state = .installing("앱 교체 및 재시작 중…")
                try ReleaseUpdater.replaceAndRelaunch(
                    stagedAppURL: stagedAppURL,
                    targetAppURL: Bundle.main.bundleURL
                )
                try? await Task.sleep(for: .milliseconds(150))
                NSApp.terminate(nil)
            } catch UpdateError.notRunningFromAppBundle(let url) {
                NSWorkspace.shared.open(url)
                self.state = .failed("개발 실행 모드에서는 브라우저를 통해 릴리즈 페이지를 엽니다.")
            } catch UpdateError.bundleNotWritable {
                NSWorkspace.shared.open(release.dmgAsset?.downloadURL ?? release.htmlURL)
                self.state = .failed("현재 설치 경로에 쓰기 권한이 없어 설치 파일 다운로드를 시작했습니다.")
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func openReleasePage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.htmlURL)
    }
}

struct UpdateBannerView: View {
    @ObservedObject var updater: UpdateModel
    let release: ReleaseInfo

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("새 버전 업데이트 가능")
                        .font(.callout.weight(.semibold))
                    StatusPill(text: release.tagName, color: .blue, icon: "sparkles")
                }
                Text("현재 v\(updater.currentVersion.description) → \(release.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !release.notes.isEmpty {
                Button("변경 내역") {
                    updater.showingReleaseNotes = true
                }
                .controlSize(.small)
                .popover(isPresented: $updater.showingReleaseNotes, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(release.title)
                                .font(.headline)
                            Spacer()
                            Button("GitHub에서 열기") {
                                updater.openReleasePage(release)
                            }
                            .controlSize(.small)
                        }
                        Divider()
                        ScrollView {
                            Text(release.notes)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(14)
                    .frame(width: 420, height: 260)
                }
            }

            Button {
                updater.install(release)
            } label: {
                Label("지금 업데이트 및 재시작", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.small)

            Button {
                updater.dismissedTag = release.tagName
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("이번 세션에서 배너 닫기")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.09))
    }
}
