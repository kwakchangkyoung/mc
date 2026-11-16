import MacCleanCore
import SwiftUI

@MainActor
final class StatusModel: ObservableObject {
    @Published var snapshot = StatusSnapshot()
    @Published var ready = false
    private let collector = StatusCollector()
    private var task: Task<Void, Never>?

    /// Poll while the dashboard is visible; `stop` (or deinit of the model)
    /// ends the loop. self is weak so a closed window's model can't be kept alive.
    func start() {
        guard task == nil else { return }
        task = Task { [collector, weak self] in
            while !Task.isCancelled, let self {
                let s = await Task.detached(priority: .utility) { collector.collect() }.value
                self.snapshot = s
                self.ready = true
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

struct DashboardView: View {
    @ObservedObject var model: StatusModel

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 16)]

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(s)
                LazyVGrid(columns: columns, spacing: 16) {
                    MetricCard(title: "CPU", value: percent(s.cpu.usage), progress: s.cpu.usage / 100,
                               detail: String(format: "부하 %.2f · %.2f · %.2f", s.cpu.load.0, s.cpu.load.1, s.cpu.load.2)
                                   + "\n코어 \(s.cpu.logicalCores)개 (P \(s.cpu.performanceCores) · E \(s.cpu.efficiencyCores))")
                    MetricCard(title: "메모리", value: percent(s.memory.usedPercent), progress: s.memory.usedPercent / 100,
                               detail: "\(bytes(Int64(s.memory.used))) / \(bytes(Int64(s.memory.total)))"
                                   + "\n스왑 \(bytes(Int64(s.memory.swapUsed))) · 압박 \(pressureLabel(s.memory.pressure))")
                    ForEach(s.disks, id: \.mount) { d in
                        MetricCard(title: "디스크 · \(d.name)", value: percent(d.usedPercent), progress: d.usedPercent / 100,
                                   detail: "여유 \(bytes(d.free)) / \(bytes(d.total))\n제거 가능 \(bytes(d.purgeable))")
                    }
                    MetricCard(title: "디스크 I/O", value: String(format: "%.1f MB/s", s.diskReadMBps + s.diskWriteMBps),
                               progress: nil,
                               detail: String(format: "읽기 %.1f MB/s · 쓰기 %.1f MB/s", s.diskReadMBps, s.diskWriteMBps))
                    MetricCard(title: "네트워크", value: String(format: "↓ %.2f  ↑ %.2f MB/s",
                                                             s.network.reduce(0) { $0 + $1.rxMBps },
                                                             s.network.reduce(0) { $0 + $1.txMBps }),
                               progress: nil, detail: s.network.map(\.name).joined(separator: ", "))
                    MetricCard(title: "GPU", value: s.gpuUsage.map(percent) ?? "–", progress: s.gpuUsage.map { $0 / 100 },
                               detail: s.chip)
                    if let b = s.battery {
                        MetricCard(title: "배터리", value: "\(b.percent)%", progress: Double(b.percent) / 100,
                                   detail: batteryDetail(b))
                    }
                }
                ProcessTable(processes: s.topProcesses)
            }
            .padding(20)
        }
        .redacted(reason: model.ready ? [] : .placeholder)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func header(_ s: StatusSnapshot) -> some View {
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle().trim(from: 0, to: CGFloat(s.health.score) / 100)
                    .stroke(scoreColor(s.health.score), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(s.health.score)").font(.system(size: 30, weight: .semibold, design: .rounded))
            }
            .frame(width: 90, height: 90)
            VStack(alignment: .leading, spacing: 4) {
                Text("시스템 상태 · \(healthLabel(s.health.label))").font(.title2.weight(.semibold))
                Text(s.health.issues.isEmpty ? "문제 없음" : s.health.issues.map(issueLabel).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                Text("\(s.modelIdentifier) · \(s.osVersion) · 가동 \(uptime(s.uptime))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func batteryDetail(_ b: BatteryMetrics) -> String {
        var parts: [String] = []
        parts.append(b.isCharging ? "충전 중" : (b.isPluggedIn ? "전원 연결됨" : "배터리 사용 중"))
        if let m = b.minutesRemaining { parts.append("\(m / 60)시간 \(m % 60)분") }
        var line2: [String] = []
        if let c = b.cycleCount { line2.append("사이클 \(c)") }
        if let h = b.healthPercent { line2.append("최대 용량 \(h)%") }
        return parts.joined(separator: " · ") + "\n" + line2.joined(separator: " · ")
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let progress: Double?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            if let progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(barColor(progress))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func barColor(_ p: Double) -> Color { p > 0.9 ? .red : (p > 0.75 ? .orange : .accentColor) }
}

struct ProcessTable: View {
    let processes: [ProcessMetrics]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CPU 사용 상위 프로세스").font(.headline)
            Table(processes) {
                TableColumn("이름", value: \.name)
                TableColumn("PID") { Text(String($0.pid)).monospacedDigit() }.width(70)
                TableColumn("CPU %") { Text(String(format: "%.1f", $0.cpu)).monospacedDigit() }.width(70)
                TableColumn("메모리 %") { Text(String(format: "%.1f", $0.memPercent)).monospacedDigit() }.width(80)
            }
            .frame(height: 170)
        }
    }
}

// MARK: formatting

func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }
func bytes(_ b: Int64) -> String { ByteFormat.string(b) }

func uptime(_ t: TimeInterval) -> String {
    let days = Int(t) / 86_400
    let hours = Int(t) % 86_400 / 3600
    return days > 0 ? "\(days)일 \(hours)시간" : "\(hours)시간"
}

func scoreColor(_ score: Int) -> Color {
    score >= 85 ? .green : (score >= 65 ? .blue : (score >= 45 ? .orange : .red))
}

func pressureLabel(_ p: MemoryPressure) -> String {
    switch p {
    case .normal: return "정상"
    case .warn: return "주의"
    case .critical: return "위험"
    case .unknown: return "알 수 없음"
    }
}

func healthLabel(_ label: String) -> String {
    ["Excellent": "매우 좋음", "Good": "좋음", "Fair": "보통", "Needs Attention": "점검 필요"][label] ?? label
}

func issueLabel(_ issue: String) -> String {
    [
        "High CPU": "CPU 사용률 높음", "High Memory": "메모리 사용률 높음", "Memory Pressure": "메모리 압박",
        "Critical Memory": "메모리 압박 심각", "Disk Almost Full": "디스크 거의 가득 참",
        "Heavy Disk IO": "디스크 I/O 많음", "Battery Service Soon": "배터리 점검 필요",
        "Restart Recommended": "재시동 권장",
    ][issue] ?? issue
}
