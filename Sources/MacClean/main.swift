import Foundation
import MacCleanCore

// Headless modes used to compare results with Mole CLI (`mo status --json`, `mo clean --dry-run`).
let arguments = CommandLine.arguments
if arguments.contains("--status") {
    let collector = StatusCollector()
    _ = collector.collect()
    Thread.sleep(forTimeInterval: 1)
    HeadlessReport.printStatus(collector.collect())
} else if arguments.contains("--clean-dry-run") {
    HeadlessReport.printCleanDryRun()
} else {
    MacCleanApp.main()
}
