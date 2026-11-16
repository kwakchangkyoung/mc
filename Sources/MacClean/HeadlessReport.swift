import Foundation
import MacCleanCore

/// Plain-text output for comparing with Mole CLI. Never deletes anything.
enum HeadlessReport {
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

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
            fail("whitelist unreadable: \(error)")
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

    /// `mo analyze --json <path>` equivalent: children + sizes, never deletes.
    static func printAnalyze(_ path: String) {
        let result: AnalyzeResult
        do { result = try DiskScanner().scan(path) } catch {
            fail("analyze failed: \(error)")
        }
        for e in result.entries {
            print("\(e.isDir ? "d" : "f") \(ByteFormat.string(e.size, partial: e.partial))\t\(e.itemCount)\t\(e.path)")
        }
        for f in result.largeFiles { print("L \(ByteFormat.string(f.size))\t\(f.path)") }
        print("TOTAL \(ByteFormat.string(result.totalSize)) \(result.totalFiles) items"
              + (result.partial ? " (partial)" : ""))
    }

    /// `mo uninstall --dry-run <app>` equivalent: app bundle + leftovers, never deletes.
    static func printUninstallDryRun(_ query: String) {
        let engine: UninstallEngine
        do { engine = try AppEnvironment.current.makeUninstallEngine() } catch {
            fail("whitelist unreadable: \(error)")
        }
        let inventory = AppInventory(home: AppEnvironment.current.home)
        var apps = inventory.discover(protection: engine.deleter.policy.protection)
        let q = query.lowercased()
        let matched = apps.indices.filter {
            apps[$0].bundleID.lowercased() == q || apps[$0].name.lowercased().contains(q)
        }
        if matched.isEmpty {
            fail("no installed app matches '\(query)'")
        }
        // only the reported apps need their bundle size measured
        for i in matched { apps[i].size = SizeCalculator.allocatedSize(of: apps[i].path) }
        let matches = matched.map { apps[$0] }
        let probes = ProbeContext.capture()
        for app in matches {
            let plan = engine.plan(for: app,
                                   siblings: UninstallEngine.siblings(of: app, in: apps),
                                   probes: probes)
            print("## \(app.name) \(app.version ?? "") (\(app.bundleID))")
            print("  APP \(plan.bundleItem.path)\t\(plan.bundleItem.size.bytes)")
            for item in plan.leftovers {
                print("  \(item.requiresAdmin ? "ADMIN" : "OK")\t\(item.path)\t\(item.size.bytes)")
            }
            for s in plan.skipped { print("  SKIP\t\(s.path)\t\(s.reason.rawValue)") }
            if let vendor = app.officialUninstaller {
                print("  NOTE official uninstaller required: \(vendor)")
            }
        }
    }

    /// `mo optimize --dry-run` equivalent: every task + why it would run or skip.
    /// Dry-run tasks only read state — nothing is changed.
    static func printOptimizeDryRun() {
        let engine: OptimizeEngine
        do { engine = try AppEnvironment.current.makeOptimizeEngine() } catch {
            fail("whitelist unreadable: \(error)")
        }
        for line in OptimizeDiagnostics.run() { print("D \(line)") }
        let probes = ProbeContext.capture()
        var counts: [OptimizeOutcomeKind: Int] = [:]
        for task in OptimizeTask.allCases {
            let outcome = engine.run(task, dryRun: true, probes: probes)
            counts[outcome.kind, default: 0] += 1
            print("\(outcome.kind.rawValue)\t\(task.id)\t\(outcome.message)")
            for d in outcome.detail { print("  \(d)") }
        }
        print("TOTAL " + OptimizeOutcomeKind.allCases
            .compactMap { kind in counts[kind].map { "\(kind.rawValue) \($0)" } }
            .joined(separator: " | "))
    }
}
