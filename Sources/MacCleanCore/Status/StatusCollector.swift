import Foundation

/// Collects a StatusSnapshot. Call `collect()` about once per second; deltas use the previous call.
/// Slow sources (processes, GPU, battery details) refresh less often, like Mole's fast/full schedule.
public final class StatusCollector: @unchecked Sendable {
    private let cpu = CPUSampler()
    private let diskIO = DiskIOSampler()
    private let network = NetworkSampler()
    private var last = StatusSnapshot()
    private var lastSlow: Date = .distantPast
    private var lastProcesses: Date = .distantPast
    private let lock = NSLock()

    public init() {
        last.hostName = ProcessInfo.processInfo.hostName
        let v = ProcessInfo.processInfo.operatingSystemVersion
        last.osVersion = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        last.modelIdentifier = Sysctl.string("hw.model") ?? ""
        last.chip = Sysctl.string("machdep.cpu.brand_string") ?? ""
    }

    public func collect() -> StatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = last
        let now = Date()
        s.cpu = cpu.sample()
        s.memory = collectMemory()
        let io = diskIO.sample()
        s.diskReadMBps = io.read
        s.diskWriteMBps = io.write
        s.network = network.sample()
        s.uptime = collectUptime()
        if now.timeIntervalSince(lastProcesses) >= 2 {
            s.topProcesses = collectTopProcesses()
            lastProcesses = now
        }
        if now.timeIntervalSince(lastSlow) >= 30 || s.disks.isEmpty {
            s.disks = collectDisks()
            s.battery = collectBattery()
            lastSlow = now
        }
        s.gpuUsage = collectGPUUsage()
        s.health = HealthCalculator.compute(cpu: s.cpu.usage, memory: s.memory.usedPercent,
                                            pressure: s.memory.pressure, disk: s.disks.first,
                                            diskIOMBps: s.diskReadMBps + s.diskWriteMBps,
                                            battery: s.battery, uptime: s.uptime)
        last = s
        return s
    }
}
