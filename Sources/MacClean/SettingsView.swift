import MacCleanCore
import SwiftUI

struct SettingsView: View {
    private let env = AppEnvironment.current

    var body: some View {
        Form {
            Section("권한") {
                LabeledContent("전체 디스크 접근") {
                    Text(env.hasFullDiskAccess() ? "허용됨" : "허용 안 됨")
                }
                Button("개인정보 보호 설정 열기") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
            Section("화이트리스트") {
                Text("정리에서 제외할 경로를 한 줄에 하나씩 적습니다(`~` 사용 가능, `#`은 주석). "
                     + "파일이 없으면 기본 보호 목록을 쓰고, 안전 패턴은 항상 함께 적용됩니다.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("파일", value: env.whitelistFile.path)
                Button("Finder에서 보기") {
                    try? FileManager.default.createDirectory(at: env.supportDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([env.supportDirectory])
                }
            }
            Section("기록") {
                LabeledContent("작업 로그", value: env.logDirectory.appendingPathComponent("operations.log").path)
            }
            Section("정보") {
                Text("맥클린은 Mole(github.com/tw93/Mole, GPL-3.0)의 정리 규칙과 안전 장치를 Swift로 옮긴 앱입니다. "
                     + "Mole 프로젝트와는 관련이 없습니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
