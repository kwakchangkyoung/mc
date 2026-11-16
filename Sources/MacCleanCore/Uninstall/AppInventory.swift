import Darwin
import Foundation

/// One installed `.app` bundle eligible for uninstall.
public struct InstalledApp: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Display name (`.app` stripped); falls back to the filename like Mole.
    public let name: String
    /// "unknown" when Info.plist lacks CFBundleIdentifier (Mole does the same).
    public let bundleID: String
    public let version: String?
    /// CFBundleExecutable, used for the running-process check.
    public let executable: String?
    /// Allocated bundle size, measured after discovery.
    public var size: SizeResult
    /// kMDItemLastUsedDate, else the bundle's mtime.
    public let lastUsed: Date?
    /// dev:inode bound at scan time; re-checked by SafeDeleter before any move to Trash.
    public let identity: PathIdentity
    /// Vendor name when the app must be removed with its own uninstaller
    /// (Mole OFFICIAL_UNINSTALLER_RULES) — such apps are refused at execution.
    public let officialUninstaller: String?
}

/// Mole `scan_applications` (bin/uninstall.sh): enumerate `*.app` under /Applications,
/// ~/Applications and the Input Methods dirs, up to depth 3. Hidden folders are skipped,
/// apps nested inside other apps are never reached, symlinks resolving to system paths are
/// dropped, and SYSTEM_CRITICAL bundle ids (unless APPLE_UNINSTALLABLE) are excluded.
public struct AppInventory: Sendable {
    public let roots: [String]

    public init(home: String) {
        roots = ["/Applications", home + "/Applications",
                 "/Library/Input Methods", home + "/Library/Input Methods"]
    }

    public init(roots: [String]) {
        self.roots = roots
    }

    /// `sizeDeadline` bounds the parallel bundle sizing pass, like Mole's du timeout.
    public func scan(protection: ProtectionPolicy,
                     sizeDeadline: Date = Date().addingTimeInterval(30)) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for root in roots { collect(root, depth: 1, into: &apps, protection: protection) }

        // dedupe on bundle_id|basename; earlier roots win (Mole priority order)
        var seen = Set<String>()
        apps = apps.filter {
            seen.insert($0.bundleID.lowercased() + "|" + ($0.path as NSString).lastPathComponent).inserted
        }

        // sizes in parallel, same pattern as CleanScanner
        var sizes = [SizeResult](repeating: .zero, count: apps.count)
        sizes.withUnsafeMutableBufferPointer { buf in
            let s = buf
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                s[i] = SizeCalculator.allocatedSize(of: apps[i].path, deadline: sizeDeadline)
            }
        }
        for i in apps.indices { apps[i].size = sizes[i] }

        // Mole sorts by last-used ascending: least recently used first.
        apps.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        return apps
    }

    private func collect(_ dir: String, depth: Int, into apps: inout [InstalledApp],
                         protection: ProtectionPolicy) {
        guard depth <= 3, let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else { return }
        for name in names.sorted() {
            if name.hasPrefix(".") && !name.lowercased().hasSuffix(".app") { continue }
            let path = dir + "/" + name
            if name.lowercased().hasSuffix(".app") {
                if let app = read(path, depth: depth, protection: protection) { apps.append(app) }
            } else if FileStat.isDirectory(path) {
                collect(path, depth: depth + 1, into: &apps, protection: protection)
            }
        }
    }

    private func read(_ path: String, depth: Int, protection: ProtectionPolicy) -> InstalledApp? {
        var st = stat()
        // symlinked .app (e.g. brew casks): skip when it resolves to a system path
        if FileStat.isSymlink(path) {
            guard let real = FileStat.realPath(path),
                  !["/System/", "/usr/bin/", "/usr/lib/", "/bin/", "/sbin/", "/private/etc/"]
                    .contains(where: { real.hasPrefix($0) }) else { return nil }
        }
        guard followStat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }

        let info = Bundle(path: path)?.infoDictionary
        var bundleID = (info?["CFBundleIdentifier"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if bundleID.isEmpty { bundleID = "unknown" }
        if protection.shouldProtectFromUninstall(bundleID) { return nil }
        // LSBackgroundOnly helpers are only listed at a scan-root top level
        if depth > 1, info?["LSBackgroundOnly"] as? Bool == true { return nil }

        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (info?["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fileName
        let version = info?["CFBundleShortVersionString"] as? String
            ?? info?["CFBundleVersion"] as? String
        let executable = info?["CFBundleExecutable"] as? String
        let lastUsed = Self.lastUsedDate(path) ?? FileStat.modificationDate(path)
        return InstalledApp(path: path, name: name, bundleID: bundleID, version: version,
                            executable: executable, size: .zero, lastUsed: lastUsed,
                            identity: PathIdentity.capture(path),
                            officialUninstaller: protection.officialUninstallerVendor(
                                bundleID: bundleID, name: name))
    }

    /// Mole uses `mdls kMDItemLastUsedDate`; NSMetadataItem is the same Spotlight index.
    private static func lastUsedDate(_ path: String) -> Date? {
        guard let item = NSMetadataItem(url: URL(fileURLWithPath: path)) else { return nil }
        return item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
    }
}
