import AppKit
import MacCleanCore
import SwiftUI

struct SettingsView: View {
    private let env = AppEnvironment.current
    @State private var hasFDA = AppEnvironment.current.hasFullDiskAccess()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeaderBar(pane: .settings) {
                Button {
                    hasFDA = env.hasFullDiskAccess()
                } label: {
                    Label("상태 새로고침", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            Divider()
            Form {
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
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 36, height: 36)
                            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("맥클린 (MacClean)")
                                    .fontWeight(.semibold)
                                StatusPill(text: "v0.1.0", color: .blue)
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
}
