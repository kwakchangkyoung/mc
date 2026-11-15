import Foundation

/// File locations and wiring for the safety stack.
public struct AppEnvironment: Sendable {
    public let home: String
    public let supportDirectory: URL
    public let logDirectory: URL
    public var whitelistFile: URL { supportDirectory.appendingPathComponent("whitelist") }

    public static let current = AppEnvironment(home: NSHomeDirectory())

    public init(home: String) {
        self.home = home
        supportDirectory = URL(fileURLWithPath: home + "/Library/Application Support/MacClean")
        logDirectory = URL(fileURLWithPath: home + "/Library/Logs/MacClean")
    }

    /// Fails closed when an existing whitelist cannot be read.
    public func makeCleanEngine() throws -> CleanEngine {
        let protection = ProtectionPolicy(home: home, ownLogDirectory: logDirectory.path)
        let policy = PathPolicy(home: home, protection: protection)
        let whitelist = try Whitelist.load(file: whitelistFile, home: home)
        let deleter = SafeDeleter(policy: policy, whitelist: whitelist, log: OperationLog(directory: logDirectory))
        return CleanEngine(home: home, deleter: deleter)
    }

    /// Full Disk Access probe (Mole `has_full_disk_access`): a TCC-protected directory must be listable.
    public func hasFullDiskAccess() -> Bool {
        for path in [home + "/Library/Safari", home + "/Library/Mail", home + "/.Trash"] where FileStat.exists(path) {
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
        return true
    }
}
