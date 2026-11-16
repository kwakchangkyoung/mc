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

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 14)]

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard(s)
                LazyVGrid(columns: columns, spacing: 14) {
                    MetricCard(
                        title: "CPU",
                        icon: "cpu.fill",
                        tint: .blue,
                        value: percent(s.cpu.usage),
                        progress: s.cpu.usage / 100,
                        primaryDetail: String(format: "부하 평균  %.2f · %.2f · %.2f", s.cpu.load.0, s.cpu.load.1, s.cpu.load.2),
                        secondaryDetail: "코어 \(s.cpu.logicalCores)개 (P \(s.cpu.performanceCores) · E \(s.cpu.efficiencyCores))"
                    )
                    MetricCard(
                        title: "메모리",
                        icon: "memorychip.fill",
                        tint: .purple,
                        value: percent(s.memory.usedPercent),
                        progress: s.memory.usedPercent / 100,
                        primaryDetail: "\(bytes(Int64(s.memory.used))) / \(bytes(Int64(s.memory.total))) 사용 중",
                        secondaryDetail: "스왑 \(bytes(Int64(s.memory.swapUsed))) · 압박 \(pressureLabel(s.memory.pressure))"
                    )
                    ForEach(s.disks, id: \.mount) { d in
                        MetricCard(
                            title: "디스크 · \(d.name)",
                            icon: "internaldrive.fill",
                            tint: .indigo,
                            value: percent(d.usedPercent),
                            progress: d.usedPercent / 100,
                            primaryDetail: "여유 \(bytes(d.free)) / 전체 \(bytes(d.total))",
                            secondaryDetail: "제거 가능(Purgeable) \(bytes(d.purgeable))"
                        )
                    }
                    MetricCard(
                        title: "디스크 I/O",
                        icon: "arrow.up.arrow.down.circle.fill",
                        tint: .teal,
                        value: String(format: "%.1f MB/s", s.diskReadMBps + s.diskWriteMBps),
                        progress: nil,
                        primaryDetail: String(format: "읽기 %.1f MB/s", s.diskReadMBps),
                        secondaryDetail: String(format: "쓰기 %.1f MB/s", s.diskWriteMBps)
                    )
                    MetricCard(
                        title: "네트워크",
                        icon: "network",
                        tint: .cyan,
                        value: String(format: "↓%.1f ↑%.1f MB/s",
                                      s.network.reduce(0) { $0 + $1.rxMBps },
                                      s.network.reduce(0) { $0 + $1.txMBps }),
                        progress: nil,
                        primaryDetail: "실시간 수신 · 송신 처리량",
                        secondaryDetail: s.network.isEmpty ? "활성 인터페이스 없음" : "인터페이스: " + s.network.map(\.name).joined(separator: ", ")
                    )
                    MetricCard(
                        title: "GPU",
                        icon: "sparkles.tv.fill",
                        tint: .mint,
                        value: s.gpuUsage.map(percent) ?? "–",
                        progress: s.gpuUsage.map { $0 / 100 },
                        primaryDetail: s.chip.isEmpty ? "Apple 그래픽 프로세서" : s.chip,
                        secondaryDetail: s.gpuUsage != nil ? "그래픽 엔진 가동률" : "사용률 정보 없음"
                    )
                    if let b = s.battery {
                        MetricCard(
                            title: "배터리",
                            icon: b.isCharging ? "battery.100percent.bolt" : "battery.100percent",
                            tint: .green,
                            value: "\(b.percent)%",
                            progress: Double(b.percent) / 100,
                            primaryDetail: batteryLine1(b),
                            secondaryDetail: batteryLine2(b)
                        )
                    }
                }
                ProcessTable(processes: s.topProcesses)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .redacted(reason: model.ready ? [] : .placeholder)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func heroCard(_ s: StatusSnapshot) -> some View {
        let color = scoreColor(s.health.score)
        return HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.16), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(s.health.score) / 100)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.75), color],
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(s.health.score)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("점수")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("시스템 상태")
                        .font(.title2.weight(.bold))
                    StatusPill(
                        text: healthLabel(s.health.label),
                        color: color,
                        icon: s.health.score >= 85 ? "checkmark.seal.fill" : "info.circle.fill"
                    )
                }

                if s.health.issues.isEmpty {
                    Label("현재 감지된 성능 저하 또는 자원 병목이 없습니다", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(s.health.issues, id: \.self) { issue in
                            StatusPill(text: issueLabel(issue), color: .orange, icon: "exclamationmark.triangle.fill")
                        }
                    }
                }

                HStack(spacing: 12) {
                    if !s.modelIdentifier.isEmpty {
                        metaChip(icon: "laptopcomputer", text: s.modelIdentifier)
                    }
                    if !s.osVersion.isEmpty {
                        metaChip(icon: "macwindow", text: s.osVersion)
                    }
                    metaChip(icon: "clock", text: "가동 \(uptime(s.uptime))")
                }
            }
            Spacer()
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [color.opacity(0.08), Color(nsColor: .controlBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 1)
        )
    }

    private func metaChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func batteryLine1(_ b: BatteryMetrics) -> String {
        var parts: [String] = []
        parts.append(b.isCharging ? "충전 중" : (b.isPluggedIn ? "전원 어댑터 연결됨" : "배터리 사용 중"))
        if let m = b.minutesRemaining { parts.append("남은 시간 \(m / 60)시간 \(m % 60)분") }
        return parts.joined(separator: " · ")
    }

    private func batteryLine2(_ b: BatteryMetrics) -> String {
        var parts: [String] = []
        if let c = b.cycleCount { parts.append("사이클 \(c)회") }
        if let h = b.healthPercent { parts.append("최대 용량 \(h)%") }
        if let t = b.temperatureC { parts.append(String(format: "%.1f°C", t)) }
        return parts.isEmpty ? "상태 정상" : parts.joined(separator: " · ")
    }
}

struct MetricCard: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let progress: Double?
    let primaryDetail: String
    let secondaryDetail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }

            if let progress {
                GeometryReader { geo in
                    let clamped = min(max(progress, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.7))
                        Capsule()
                            .fill(barColor(clamped))
                            .frame(width: max(clamped > 0 ? 6 : 0, geo.size.width * clamped))
                    }
                }
                .frame(height: 7)
            } else {
                Divider().opacity(0.5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryDetail)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineLimit(1)
                Text(secondaryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func barColor(_ p: Double) -> Color {
        p > 0.9 ? .red : (p > 0.75 ? .orange : tint)
    }
}

struct ProcessTable: View {
    let processes: [ProcessMetrics]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("CPU 사용 상위 프로세스", systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("1초 주기 갱신")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Table(processes) {
                TableColumn("프로세스 이름") { proc in
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(proc.name)
                            .fontWeight(.medium)
                    }
                }
                TableColumn("PID") { proc in
                    Text(String(proc.pid))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(75)
                TableColumn("CPU 점유율") { proc in
                    HStack(spacing: 8) {
                        Text(String(format: "%.1f%%", proc.cpu))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        MiniBar(fraction: min(proc.cpu / 100, 1), color: proc.cpu > 50 ? .orange : .blue)
                    }
                }
                .width(140)
                TableColumn("메모리 점유율") { proc in
                    HStack(spacing: 8) {
                        Text(String(format: "%.1f%%", proc.memPercent))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        MiniBar(fraction: min(proc.memPercent / 50, 1), color: .purple)
                    }
                }
                .width(140)
            }
            .frame(height: 175)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

struct MiniBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
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
