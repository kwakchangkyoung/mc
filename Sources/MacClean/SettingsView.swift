import AppKit
import MacCleanCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: UpdateModel
    private let env = AppEnvironment.current
    @State private var hasFDA = AppEnvironment.current.hasFullDiskAccess()

    init(updater: UpdateModel) {
        self.updater = updater
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.2.3"
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeaderBar(pane: .settings) {
                Button {
                    hasFDA = env.hasFullDiskAccess()
                    updater.checkForUpdates()
                } label: {
                    Label("상태 새로고침", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            Divider()
            Form {
                Section("소프트웨어 업데이트") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            AppLogoView(size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("현재 버전 v\(appVersion)")
                                        .fontWeight(.semibold)
                                    updateStatusBadge
                                }
                                Text(updateSubtitleText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            updateActionButtons
                        }

                        if case .available(let release) = updater.state, !release.notes.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(release.title) 릴리즈 노트")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("GitHub에서 열기") {
                                        updater.openReleasePage(release)
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                                Text(release.notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        Divider()

                        Toggle(isOn: $updater.autoCheckUpdates) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("앱 시작 시 자동으로 업데이트 확인")
                                Text("GitHub 공개 릴리즈 API만 조회하며 어떠한 개인정보나 기기 정보도 전송하지 않습니다.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("디스크 접근 권한") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("전체 디스크 접근 권한 (Full Disk Access)")
                                .fontWeight(.medium)
                            Text("휴지통, Safari 캐시, Mail 데이터베이스, 샌드박스 컨테이너 스캔에 필요합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(
                            text: hasFDA ? "허용됨" : "권한 필요",
                            color: hasFDA ? .green : .orange,
                            icon: hasFDA ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                        )
                        Button("개인정보 보호 설정 열기") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("화이트리스트 (보호 경로)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("정리에서 항상 제외할 경로를 한 줄에 하나씩 작성합니다 (`~` 및 `*` 와일드카드 지원, `#`은 주석). 파일이 없어도 기본 보호 목록과 안전 패턴은 항상 함께 적용됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.secondary)
                            Text(env.whitelistFile.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Button("Finder에서 열기") {
                                try? FileManager.default.createDirectory(at: env.supportDirectory, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([env.supportDirectory])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("작업 감사 로그") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("삭제 및 휴지통 이동 기록")
                                .fontWeight(.medium)
                            Text(env.logDirectory.appendingPathComponent("operations.log").path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("로그 폴더 열기") {
                            try? FileManager.default.createDirectory(at: env.logDirectory, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([env.logDirectory])
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("애플리케이션 정보") {
                    HStack(spacing: 12) {
                        AppLogoView(size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("맥클린 (MacClean)")
                                    .fontWeight(.semibold)
                                StatusPill(text: "v\(appVersion)", color: .blue)
                                StatusPill(text: "GPL-3.0", color: .secondary)
                            }
                            Text("Mole (github.com/tw93/Mole, GPL-3.0)의 정리 규칙과 안전 장치를 Swift/SwiftUI 네이티브로 구현한 앱입니다. Mole 프로젝트와는 관련이 없습니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { hasFDA = env.hasFullDiskAccess() }
    }

    @ViewBuilder
    private var updateStatusBadge: some View {
        switch updater.state {
        case .idle:
            StatusPill(text: "대기 중", color: .secondary)
        case .checking:
            StatusPill(text: "확인 중…", color: .blue, icon: "arrow.triangle.2.circlepath")
        case .upToDate:
            StatusPill(text: "최신 버전", color: .green, icon: "checkmark.circle.fill")
        case .available(let release):
            StatusPill(text: "\(release.tagName) 사용 가능", color: .blue, icon: "sparkles")
        case .installing:
            StatusPill(text: "설치 중…", color: .orange, icon: "arrow.down.circle.fill")
        case .failed:
            StatusPill(text: "확인 실패", color: .red, icon: "exclamationmark.triangle.fill")
        }
    }

    private var updateSubtitleText: String {
        switch updater.state {
        case .idle:
            return "GitHub Releases에서 새 버전 출시 여부를 확인할 수 있습니다."
        case .checking:
            return "GitHub에서 최신 릴리즈 정보를 확인하고 있습니다…"
        case .upToDate:
            return "현재 가장 최신 버전의 맥클린을 사용하고 있습니다."
        case .available(let release):
            return "새 버전(\(release.title))이 배포되었습니다. SHA-256 검증 후 자동으로 교체 및 재시작합니다."
        case .installing(let status):
            return status
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var updateActionButtons: some View {
        switch updater.state {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .available(let release):
            HStack(spacing: 8) {
                Button("다시 확인") {
                    updater.checkForUpdates()
                }
                Button {
                    updater.install(release)
                } label: {
                    Label("업데이트 설치 및 재시작", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        default:
            Button {
                updater.checkForUpdates()
            } label: {
                Label("지금 업데이트 확인", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}
