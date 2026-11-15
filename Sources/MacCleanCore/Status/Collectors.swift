import Darwin
import Foundation
import IOKit
import IOKit.ps

// Port of Mole cmd/status metric sources, mapped to Darwin/IOKit APIs (docs/analysis/05 §C1).

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size { return Int(Int32(truncatingIfNeeded: value)) }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

// MARK: CPU

final class CPUSampler {
    private var previous: [(busy: UInt64, total: UInt64)] = []

    func sample() -> CPUMetrics {
        var m = CPUMetrics()
        m.physicalCores = Sysctl.int("hw.physicalcpu") ?? 0
        m.logicalCores = Sysctl.int("hw.logicalcpu") ?? 0
        m.performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
        m.efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { m.load = (loads[0], loads[1], loads[2]) }

        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
                == KERN_SUCCESS, let info else { return m }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var current: [(busy: UInt64, total: UInt64)] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            current.append((user + system + nice, user + system + nice + idle))
        }
        if previous.count == current.count {
            var busySum: UInt64 = 0
            var totalSum: UInt64 = 0
            m.perCore = zip(current, previous).map { cur, prev in
                let busy = cur.busy &- prev.busy
                let total = cur.total &- prev.total
                busySum += busy
                totalSum += total
                return total > 0 ? Double(busy) / Double(total) * 100 : 0
            }
            m.usage = totalSum > 0 ? Double(busySum) / Double(totalSum) * 100 : 0
        } else {
            m.perCore = Array(repeating: 0, count: current.count)
        }
        previous = current
        return m
    }
}

// MARK: Memory

func collectMemory() -> MemoryMetrics {
    var m = MemoryMetrics()
    m.total = UInt64(Sysctl.int("hw.memsize") ?? 0)
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let page = UInt64(vm_kernel_page_size)
        // Mole (gopsutil) definition: Available = free + inactive, Used = Total − Available
        let available = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * page
        m.used = m.total > available ? m.total - available : 0
        m.cached = UInt64(stats.external_page_count) * page
    }
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
        m.swapTotal = swap.xsu_total
        m.swapUsed = swap.xsu_used
    }
    switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
    case 1: m.pressure = .normal
    case 2: m.pressure = .warn
    case 4: m.pressure = .critical
    default: m.pressure = .unknown
    }
    return m
}

// MARK: Disks

func collectDisks() -> [DiskMetrics] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                  .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                                  .volumeIsLocalKey, .volumeIsBrowsableKey]
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                     options: [.skipHiddenVolumes]) ?? []
    var result: [DiskMetrics] = []
    for url in urls {
        guard let v = try? url.resourceValues(forKeys: Set(keys)),
              v.volumeIsLocal ?? false, v.volumeIsBrowsable ?? true,
              !url.path.hasPrefix("/System/Volumes/") else { continue }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        guard total >= 1 << 30 else { continue }
        let raw = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage ?? raw
        var d = DiskMetrics()
        d.name = v.volumeName ?? url.lastPathComponent
        d.mount = url.path
        d.total = total
        // Mole reports used = total − free without purgeable space; purgeable is shown separately.
        d.free = raw
        d.purgeable = max(important - raw, 0)
        d.isInternal = v.volumeIsInternal ?? true
        result.append(d)
    }
    // internal first, root first, then larger; max 3 (Mole metrics_disk.go:133-146)
    result.sort {
        if ($0.mount == "/") != ($1.mount == "/") { return $0.mount == "/" }
        if $0.isInternal != $1.isInternal { return $0.isInternal }
        return $0.total > $1.total
    }
    return Array(result.prefix(3))
}

final class DiskIOSampler {
    private var previous: (read: UInt64, write: UInt64, at: Date)?

    func sample() -> (read: Double, write: Double) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        let now = Date()
        defer { previous = (read, write, now) }
        guard let prev = previous else { return (0, 0) }
        let dt = max(now.timeIntervalSince(prev.at), 0.1)
        let mb = 1024.0 * 1024.0
        return (Double(read &- prev.read) / mb / dt, Double(write &- prev.write) / mb / dt)
    }
}

// MARK: Network (NET_RT_IFLIST2: 64-bit counters)

final class NetworkSampler {
    private static let noisePrefixes = ["lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi", "ap"]
    private var previous: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var previousAt: Date?

    func sample() -> [NetworkInterfaceMetrics] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [] }

        var counters: [String: (rx: UInt64, tx: UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        counters[name] = (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes)
                    }
                }
                guard hdr.ifm_msglen > 0 else { break }
                offset += Int(hdr.ifm_msglen)
            }
        }
        let now = Date()
        defer { previous = counters; previousAt = now }
        guard let at = previousAt else { return [] }
        let dt = max(now.timeIntervalSince(at), 0.1)
        let mb = 1024.0 * 1024.0
        var result: [NetworkInterfaceMetrics] = []
        for (name, cur) in counters {
            guard !Self.noisePrefixes.contains(where: { name.hasPrefix($0) }), let prev = previous[name] else {
                continue
            }
            let rx = Double(cur.rx &- prev.rx) / mb / dt
            let tx = Double(cur.tx &- prev.tx) / mb / dt
            result.append(NetworkInterfaceMetrics(name: name, rxMBps: rx, txMBps: tx))
        }
        result.sort { ($0.rxMBps + $0.txMBps) > ($1.rxMBps + $1.txMBps) }
        return Array(result.prefix(3))
    }
}

// MARK: Battery

func collectBattery() -> BatteryMetrics? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
        var b = BatteryMetrics()
        let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        b.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        b.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        b.isPluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if let t = desc[kIOPSTimeToEmptyKey] as? Int, t > 0, !b.isPluggedIn { b.minutesRemaining = t }
        if let t = desc[kIOPSTimeToFullChargeKey] as? Int, t > 0, b.isCharging { b.minutesRemaining = t }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let top = props?.takeRetainedValue() as? [String: Any] {
                // macOS 27 nests the gauge values in "BatteryData"; older releases keep them top-level.
                var p = top["BatteryData"] as? [String: Any] ?? [:]
                p.merge(top) { nested, _ in nested }
                b.cycleCount = p["CycleCount"] as? Int
                let design = p["DesignCapacity"] as? Int ?? 0
                let raw = (p["AppleRawMaxCapacity"] as? Int) ?? (p["NominalChargeCapacity"] as? Int) ?? 0
                if design > 0 && raw > 0 { b.healthPercent = Swift.min(100, Int((Double(raw) / Double(design) * 100).rounded())) }
                if let t = p["Temperature"] as? Int, t != 0 { b.temperatureC = t < 1000 ? Double(t) : Double(t) / 100 }
            }
        }
        return b
    }
    return nil
}

// MARK: GPU (IOAccelerator, no root needed)

func collectGPUUsage() -> Double? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
            == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var best: Double?
    var service = IOIteratorNext(iterator)
    while service != 0 {
        if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
           let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
            best = Swift.max(best ?? 0, util)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return best
}

// MARK: Processes (ps; libproc coverage for other users is not guaranteed)

func collectTopProcesses(limit: Int = 5) -> [ProcessMetrics] {
    let r = Shell.run("/bin/ps", ["-Aceo", "pid=,pcpu=,pmem=,comm=", "-r"], timeout: 3)
    guard r.status == 0 else { return [] }
    var result: [ProcessMetrics] = []
    for line in r.stdout.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let mem = Double(parts[2])
        else { continue }
        result.append(ProcessMetrics(pid: pid, name: String(parts[3]), cpu: cpu, memPercent: mem))
    }
    result.sort { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : ($0.memPercent != $1.memPercent ? $0.memPercent > $1.memPercent : $0.pid < $1.pid) }
    return Array(result.prefix(limit))
}

// MARK: Host

func collectUptime() -> TimeInterval {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
    return Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec)
}
