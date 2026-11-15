import Foundation

/// Port of Mole `metrics_health.go:64-214`. Thermal is omitted: Mole never collects CPU temperature.
public enum HealthCalculator {
    public static func compute(cpu: Double, memory: Double, pressure: MemoryPressure, disk: DiskMetrics?,
                               diskIOMBps: Double, battery: BatteryMetrics?, uptime: TimeInterval) -> HealthScore {
        var score = 100.0
        var issues: [String] = []

        if cpu > 85 {
            score -= 30 * (cpu - 50) / 50
            issues.append("High CPU")
        } else if cpu > 50 {
            score -= 15 * (cpu - 50) / 35
        }

        if memory > 88 {
            score -= 25 * (memory - 70) / 30
            issues.append("High Memory")
        } else if memory > 70 {
            score -= 12.5 * (memory - 70) / 18
        }

        switch pressure {
        case .warn: score -= 5; issues.append("Memory Pressure")
        case .critical: score -= 15; issues.append("Critical Memory")
        default: break
        }

        if let disk {
            let d = disk.usedPercent
            if d > 93 { score -= 20 * (d - 80) / 20 } else if d > 80 { score -= 10 * (d - 80) / 13 }
            if d >= 90 && disk.free < 30_000_000_000 { issues.append("Disk Almost Full") }
        }

        if diskIOMBps > 150 {
            score -= 10
            issues.append("Heavy Disk IO")
        } else if diskIOMBps > 50 {
            score -= 10 * (diskIOMBps - 50) / 100
        }

        if let battery {
            switch battery.healthLabel {
            case "Service Soon": score -= 5; issues.append("Battery Service Soon")
            case "Fair": score -= 2
            default: break
            }
        }

        let days = uptime / 86_400
        if days > 14 { score -= 3; issues.append("Restart Recommended") } else if days > 7 { score -= 1 }

        return HealthScore(score: Int(min(max(score, 0), 100)), issues: issues)
    }
}
