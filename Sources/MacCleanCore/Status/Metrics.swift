import Foundation

public struct CPUMetrics: Sendable, Equatable {
    public var usage: Double = 0          // 0...100, all cores
    public var perCore: [Double] = []
    public var load: (Double, Double, Double) = (0, 0, 0)
    public var physicalCores = 0
    public var logicalCores = 0
    public var performanceCores = 0
    public var efficiencyCores = 0

    public static func == (a: CPUMetrics, b: CPUMetrics) -> Bool {
        a.usage == b.usage && a.perCore == b.perCore && a.load == b.load
    }
}

public enum MemoryPressure: String, Sendable { case normal, warn, critical, unknown }

public struct MemoryMetrics: Sendable, Equatable {
    public var total: UInt64 = 0
    public var used: UInt64 = 0
    public var cached: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var pressure: MemoryPressure = .unknown
    public var usedPercent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

public struct DiskMetrics: Sendable, Equatable {
    public var name = ""
    public var mount = ""
    public var total: Int64 = 0
    public var free: Int64 = 0          // excludes purgeable (statfs available)
    public var purgeable: Int64 = 0
    public var isInternal = true
    public var used: Int64 { max(total - free, 0) }
    public var usedPercent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

public struct NetworkInterfaceMetrics: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var rxMBps: Double
    public var txMBps: Double
}

public struct BatteryMetrics: Sendable, Equatable {
    public var percent: Int = 0
    public var isCharging = false
    public var isPluggedIn = false
    public var minutesRemaining: Int?   // nil = calculating / unknown
    public var cycleCount: Int?
    public var healthPercent: Int?      // max capacity / design capacity
    public var temperatureC: Double?
    public var healthLabel: String {
        guard let cap = healthPercent else { return "Unknown" }
        if cap < 60 { return "Service Soon" }
        if (cycleCount ?? 0) > 1000 || cap < 80 { return "Fair" }
        return "Healthy"
    }
}

public struct ProcessMetrics: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var cpu: Double
    public var memPercent: Double
}

public struct HealthScore: Sendable, Equatable {
    public var score: Int
    public var issues: [String]
    public var label: String {
        switch score {
        case 85...: return "Excellent"
        case 65...: return "Good"
        case 45...: return "Fair"
        default: return "Needs Attention"
        }
    }
}

public struct StatusSnapshot: Sendable, Equatable {
    public var cpu = CPUMetrics()
    public var memory = MemoryMetrics()
    public var disks: [DiskMetrics] = []
    public var diskReadMBps: Double = 0
    public var diskWriteMBps: Double = 0
    public var network: [NetworkInterfaceMetrics] = []
    public var battery: BatteryMetrics?
    public var gpuUsage: Double?          // nil = unavailable
    public var uptime: TimeInterval = 0
    public var topProcesses: [ProcessMetrics] = []
    public var hostName = ""
    public var osVersion = ""
    public var modelIdentifier = ""
    public var chip = ""
    public var health = HealthScore(score: 100, issues: [])

    public init() {}
}
