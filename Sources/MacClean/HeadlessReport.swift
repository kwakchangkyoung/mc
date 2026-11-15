import Foundation
import MacCleanCore

/// Plain-text output for comparing with Mole CLI. Never deletes anything.
enum HeadlessReport {
    static func printStatus(_ s: StatusSnapshot) {
        func gb(_ b: Int64) -> String { String(format: "%.1fGB", Double(b) / 1e9) }
        print("host \(s.hostName) \(s.osVersion) \(s.modelIdentifier) \(s.chip)")
        print(String(format: "cpu %.1f%% cores=%d/%d P=%d E=%d load=%.2f %.2f %.2f", s.cpu.usage,
                     s.cpu.physicalCores, s.cpu.logicalCores, s.cpu.performanceCores, s.cpu.efficiencyCores,
                     s.cpu.load.0, s.cpu.load.1, s.cpu.load.2))
        print(String(format: "memory used=%.1f%% total=%@ cached=%@ swap=%@/%@ pressure=%@", s.memory.usedPercent,
                     gb(Int64(s.memory.total)), gb(Int64(s.memory.cached)), gb(Int64(s.memory.swapUsed)),
                     gb(Int64(s.memory.swapTotal)), s.memory.pressure.rawValue))
        for d in s.disks {
            print(String(format: "disk %@ %@ used=%.1f%% total=%@ free=%@ purgeable=%@ internal=%@", d.name, d.mount,
                         d.usedPercent, gb(d.total), gb(d.free), gb(d.purgeable), d.isInternal ? "yes" : "no"))
        }
        print(String(format: "diskio read=%.2fMB/s write=%.2fMB/s", s.diskReadMBps, s.diskWriteMBps))
        for n in s.network { print(String(format: "net %@ rx=%.3fMB/s tx=%.3fMB/s", n.name, n.rxMBps, n.txMBps)) }
        if let b = s.battery {
            print("battery \(b.percent)% charging=\(b.isCharging) plugged=\(b.isPluggedIn) cycles=\(b.cycleCount ?? -1) "
                  + "health=\(b.healthPercent ?? -1)% \(b.healthLabel) temp=\(b.temperatureC ?? -1)")
        }
        print("gpu \(s.gpuUsage.map { String(format: "%.0f%%", $0) } ?? "n/a")")
        print(String(format: "uptime %.1fh", s.uptime / 3600))
        for p in s.topProcesses { print(String(format: "proc %d %@ cpu=%.1f mem=%.1f", p.pid, p.name, p.cpu, p.memPercent)) }
        print("health \(s.health.score) \(s.health.label) \(s.health.issues.joined(separator: ", "))")
    }

    static func printCleanDryRun() {
        let engine: CleanEngine
        do { engine = try AppEnvironment.current.makeCleanEngine() } catch {
            print("whitelist unreadable: \(error)")
            exit(1)
        }
        let result = engine.scan()
        for group in result.groups {
            if let d = group.deferred {
                print("## \(group.rule.label): deferred (\(d.rawValue))")
                continue
            }
            guard !group.items.isEmpty || !group.skipped.isEmpty else { continue }
            print("## \(group.rule.label): \(ByteFormat.string(group.totalBytes, partial: group.partial)) "
                  + "\(group.items.count) items, \(group.skipped.count) skipped")
            for item in group.items { print("  \(item.path)\t\(item.size.bytes)") }
            for s in group.skipped { print("  SKIP \(s.path)\t\(s.reason.rawValue)") }
        }
        print("TOTAL \(ByteFormat.string(result.totalBytes)) \(result.itemCount) items")
    }
}
