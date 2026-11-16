import Foundation

/// Mole `run_optimize_diagnostics` (diagnostics.sh) — read-only performance checks.
/// Each finding is a user-facing line; no state is changed and nothing is detached/killed.
public enum OptimizeDiagnostics {
    public typealias Runner = OptimizeEngine.Runner

    /// CPU families Mole tracks (diagnostics.sh:65-73): id → (match regex, label).
    private static let cpuFamilies: [(regex: String, label: String)] = [
        ("cloudshell|alientsafe|aliedr", "CloudShell 백그라운드 프로세스"),
        ("syspolicyd", "syspolicyd (Gatekeeper 검사)"),
        ("windowserver", "WindowServer"),
        ("mds|mdworker|mds_stores|mdbulkimport", "Spotlight 인덱싱"),
        ("diskimagesiod|simdiskimaged", "디스크 이미지/시뮬레이터"),
    ]

    private static let runawayExcludes: Set<String> = [
        "kernel_task", "WindowServer", "mds", "mds_stores", "syspolicyd", "mdworker",
    ]

    /// The whole diagnostic pass — a few `ps`/`sysctl` calls, all read-only.
    public static func run(shell: @escaping Runner = { Shell.run($0, $1, timeout: $2) }) -> [String] {
        var findings: [String] = []
        var syspolicydSustained = false

        // CPU families: two samples 1s apart, sustained when ≥25% in both
        let first = cpuSums(shell)
        if !first.isEmpty {
            Thread.sleep(forTimeInterval: 1)
            let second = cpuSums(shell)
            for (regex, label) in cpuFamilies {
                let a = first[regex] ?? 0, b = second[regex] ?? 0
                if a >= 25 && b >= 25 {
                    if regex == "syspolicyd" { syspolicydSustained = true }
                    findings.append("병목 가능성: \(label) — CPU ~\(Int((a + b) / 2))% 지속")
                }
            }
        }

        // memory pressure: swap ≥50% or memory_pressure free <15%
        let swap = shell("/usr/sbin/sysctl", ["-n", "vm.swapusage"], 3).stdout
        var memoryPressure = false
        if let used = Self.match(#"used = ([\d.]+)"#, in: swap).flatMap(Double.init),
           let total = Self.match(#"total = ([\d.]+)"#, in: swap).flatMap(Double.init),
           total > 0, used / total >= 0.5 {
            findings.append("메모리 압박: 스왑 \(Int(used))MB / \(Int(total))MB 사용 중")
            memoryPressure = true
        }
        let pressure = shell("/usr/bin/memory_pressure", [], 5).stdout
        if let free = Self.match(#"free percentage: (\d+)%"#, in: pressure).flatMap(Int.init), free < 15 {
            findings.append("메모리 압박: 여유 메모리 \(free)%")
            memoryPressure = true
        }
        if memoryPressure {
            for line in topMemoryConsumers(shell) { findings.append("  메모리 상위: \(line)") }
        }

        // idle VMs: Virtualization.framework VM RSS 합계 > 2GB
        let vmRSS = shell("/bin/ps", ["-Ao", "rss=,command="], 5).stdout
            .split(whereSeparator: \.isNewline).reduce(Int64(0)) { sum, line in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard line.contains("Virtualization.framework"), line.contains("VirtualMachine"),
                      let rss = parts.first.flatMap({ Int64($0) }) else { return sum }
                return sum + rss
            }
        if vmRSS > 2 * 1024 * 1024 {
            findings.append("유휴 VM 감지: 가상 머신이 ~\(vmRSS / 1024 / 1024)GB 사용 중")
        }

        // runaway processes: elapsed >12h and CPU time ≥25% of elapsed
        let psOut = shell("/bin/ps", ["-Ao", "pid=,time=,etime=,comm="], 5).stdout
        for line in psOut.split(whereSeparator: \.isNewline).prefix(400) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count == 4, let pid = cols.first,
                  let cpu = parseClock(String(cols[1])),
                  let elapsed = parseClock(String(cols[2])),
                  elapsed > 12 * 3600, Double(cpu) >= Double(elapsed) * 0.25 else { continue }
            let comm = String(cols[3])
            guard !runawayExcludes.contains(comm), !comm.hasPrefix("mdworker") else { continue }
            findings.append("폭주 프로세스: \(comm)(pid \(pid)) — \(cpu / 3600)h CPU / \(elapsed / 3600)h 경과")
        }

        // mounted disk images: only worth checking when syspolicyd is burning CPU
        if syspolicydSustained {
            let info = shell("/usr/bin/hdiutil", ["info"], 8).stdout
            var mounts: [String] = []
            var devEntry = false
            for line in info.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("/dev/disk") { devEntry = true }
                if devEntry, line.hasPrefix("/Volumes/") {
                    let path = String(line)
                    if !path.hasPrefix("/System/") && !path.hasPrefix("/Library/Apple/") {
                        mounts.append(path)
                    }
                    devEntry = false
                }
            }
            if !mounts.isEmpty {
                findings.append("마운트된 디스크 이미지 \(mounts.count)개가 Gatekeeper 검사를 유발할 수 있음: "
                                + mounts.joined(separator: ", "))
            }
        }

        if findings.isEmpty { findings.append("지속적인 고CPU 병목이 감지되지 않았습니다") }
        return findings
    }

    private static func cpuSums(_ shell: Runner) -> [String: Double] {
        let out = shell("/bin/ps", ["-Aceo", "pcpu=,command="], 5).stdout
        var sums: [String: Double] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let cpu = Double(parts[0]) else { continue }
            let command = parts[1].lowercased()
            for (regex, _) in cpuFamilies where command.range(of: regex, options: .regularExpression) != nil {
                sums[regex, default: 0] += cpu
            }
        }
        return sums
    }

    /// `ps -Ao rss,comm` — RSS >256MB 상위 4개 (CoreSimulator 제외).
    private static func topMemoryConsumers(_ shell: Runner) -> [String] {
        shell("/bin/ps", ["-Ao", "rss=,comm="], 5).stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (Int64, String)? in
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let rss = Int64(parts[0]), rss > 256 * 1024,
                      !parts[1].contains("CoreSimulator") else { return nil }
                return (rss, String(parts[1]))
            }
            .sorted { $0.0 > $1.0 }
            .prefix(4)
            .map { "\(ByteFormat.string($0.0 * 1024)) \($0.1)" }
    }

    /// `[[dd-]hh:]mm:ss` → seconds.
    private static func parseClock(_ s: String) -> Int? {
        var days = 0
        var rest = s
        if let dash = s.firstIndex(of: "-") {
            guard let d = Int(s[..<dash]) else { return nil }
            days = d
            rest = String(s[s.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var seconds = 0
        for p in parts { seconds = seconds * 60 + p }
        return days * 86_400 + seconds
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
