import Foundation
import MacCleanCore

// Headless modes used to compare results with Mole CLI (`mo status --json`, `mo clean --dry-run`,
// `mo analyze --json`). The GUI launches only with no arguments — an unknown flag must not.
let usageText = """
usage: MacClean [--status | --clean-dry-run | --analyze [path] | --uninstall-dry-run <app> \
| --optimize-dry-run | --help]

"""
func usageError() -> Never {
    FileHandle.standardError.write(Data(usageText.utf8))
    exit(64)
}

// Finder may inject -psn_* / -NS* arguments; they are not user input
let args = CommandLine.arguments.dropFirst()
    .filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") }

if args.isEmpty {
    MacCleanApp.main()
} else if args == ["--status"] {
    let collector = StatusCollector()
    _ = collector.collect()
    Thread.sleep(forTimeInterval: 1)
    HeadlessReport.printStatus(collector.collect())
} else if args == ["--clean-dry-run"] {
    HeadlessReport.printCleanDryRun()
} else if args.first == "--analyze" {
    // a flag is not a path — anything else after --analyze falls back to home
    let path = args.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 }
    HeadlessReport.printAnalyze(path ?? NSHomeDirectory())
} else if args.first == "--uninstall-dry-run" {
    guard args.count > 1, !args[args.index(after: args.startIndex)].hasPrefix("-") else { usageError() }
    HeadlessReport.printUninstallDryRun(args[args.index(after: args.startIndex)])
} else if args == ["--optimize-dry-run"] {
    HeadlessReport.printOptimizeDryRun()
} else if args == ["--help"] || args == ["-h"] {
    print(usageText, terminator: "")
} else {
    usageError()
}
