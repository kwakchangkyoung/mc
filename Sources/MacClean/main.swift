import Foundation
import MacCleanCore

// Headless modes used to compare results with Mole CLI (`mo status --json`, `mo clean --dry-run`,
// `mo analyze --json`).
let arguments = CommandLine.arguments
if arguments.contains("--status") {
    let collector = StatusCollector()
    _ = collector.collect()
    Thread.sleep(forTimeInterval: 1)
    HeadlessReport.printStatus(collector.collect())
} else if arguments.contains("--clean-dry-run") {
    HeadlessReport.printCleanDryRun()
} else if let i = arguments.firstIndex(of: "--analyze") {
    let path = i + 1 < arguments.count ? arguments[i + 1] : NSHomeDirectory()
    HeadlessReport.printAnalyze(path)
} else if let i = arguments.firstIndex(of: "--uninstall-dry-run") {
    guard i + 1 < arguments.count else {
        print("usage: MacClean --uninstall-dry-run <app name or bundle id>")
        exit(64)
    }
    HeadlessReport.printUninstallDryRun(arguments[i + 1])
} else if arguments.contains("--optimize-dry-run") {
    HeadlessReport.printOptimizeDryRun()
} else {
    MacCleanApp.main()
}
