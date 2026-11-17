import Darwin
import Foundation

/// Mole `find_app_files` / `find_app_system_files` (app_protection.sh). For a selected app it
/// returns the related files that exist on disk: name-based and bundle-id-based paths under
/// the user Library, plus review-only system-domain (/Library) items that need admin rights.
/// Results that ARE the Library roots themselves or shared state roots are never produced.
public struct LeftoverFinder: Sendable {
    public let home: String

    public init(home: String) { self.home = home }

    private var lib: String { home + "/Library" }

    /// Mole `mole_is_reverse_dns_bundle_id`: "com.vendor.App" shape, alnum+hyphen components.
    public static func isReverseDNS(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(ok.contains) }
    }

    /// Channel suffixes stripped for family/base-name matching (Mole channel list).
    private static let channelSuffixes = [
        "Developer Edition", "Technology Preview", "Nightly", "Beta", "Alpha", "Canary",
        "Preview", "Insider", "Dev", "Edge", "Stable", "Release", "RC", "LTS",
    ]

    /// Base name with a trailing channel token removed ("Tor Browser Alpha" → "Tor Browser").
    public static func baseName(_ name: String) -> String {
        for suffix in channelSuffixes where name.hasSuffix(" " + suffix) {
            return String(name.dropLast(suffix.count + 1))
        }
        return name
    }

    /// Name spellings Mole tries: original, no-space, `_`, `-`, plus lowercase variants.
    static func nameVariants(_ name: String) -> [String] {
        var out: [String] = [name]
        if name.contains(" ") {
            for r in ["", "_", "-"] { out.append(name.replacingOccurrences(of: " ", with: r)) }
        }
        let base = baseName(name)
        if base != name { out.append(base) }
        var lowered: [String] = []
        for v in out {
            let l = v.lowercased()
            if l != v { lowered.append(l) }
        }
        return out + lowered
    }

    /// Bundle-id boundary match for container/extension names: `B`, `B.*`, `B-*`,
    /// `*.B`, `*.B.*` (Mole finds `B-LaunchAtLoginHelper`-style extensions).
    static func containsBoundary(_ name: String, _ b: String) -> Bool {
        name == b || name.hasPrefix(b + ".") || name.hasPrefix(b + "-")
            || name.hasSuffix("." + b) || name.contains("." + b + ".") || name.contains("." + b + "-")
    }

    /// Common-word app names never match LaunchAgent plists by name (Mole
    /// LAUNCH_AGENT_NAME_COMMON_WORDS).
    private static let commonWords: Set<String> = [
        "music", "notes", "photos", "mail", "maps", "calendar", "helper", "agent", "daemon",
        "service", "update", "updater", "sync", "backup", "cloud", "manager", "server",
        "monitor", "utility", "settings", "system", "preferences", "security", "keyboard",
        "audio", "video", "media", "player", "editor", "viewer", "launcher", "installer",
        "broker", "engine", "framework", "library", "core", "base", "tool", "utils", "app",
        "application", "desktop", "window", "menu", "bar", "dock", "status", "panel",
        "widget", "extension", "plugin", "driver", "host", "client", "network", "internet",
        "web", "files", "finder", "search", "index", "store", "cache", "log", "data",
        "database", "profile", "account", "user", "shared", "common", "control", "center",
    ]

    /// Independent CLI-tool dotdirs are never treated as an app's leftovers (Mole #993).
    private static let cliDotdirNames: Set<String> = ["claude", "opencode", "codex", "gemini"]

    private func children(_ dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    }

    private func add(_ paths: inout Set<String>, _ candidates: [String]) {
        for p in candidates where FileStat.exists(p) { paths.insert(p) }
    }

    /// A name usable in path patterns: no "/", not only dots — otherwise `./` etc. would
    /// normalize `~/Library/Preferences/./` to the Library root (Mole app_protection.sh).
    static func isUsableName(_ name: String) -> Bool {
        !name.contains("/") && name.contains(where: { $0 != "." })
    }

    /// `path` starts with `prefix` only at a `_`, `-`, `.` boundary (or equals it).
    static func hasBoundaryPrefix(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "_") || path.hasPrefix(prefix + "-")
            || path.hasPrefix(prefix + ".")
    }

    /// Executable basenames that are shared runtimes: crash reports for them belong to many
    /// apps, so only the app name may be used for DiagnosticReports matching.
    private static let sharedRuntimeNames: Set<String> = [
        "electron", "java", "node", "python", "python3", "ruby", "perl", "dotnet", "mono",
        "nwjs", "php",
    ]

    /// `getconf DARWIN_USER_CACHE_DIR` → `/var/folders/.../C/`.
    private func darwinUserCacheDir() -> String? {
        DarwinDirs.userCacheDir()
    }

    /// User-domain leftovers. `allowNamePatterns=false` when a sibling app shares the bundle id
    /// or name (Mole family-shared-leaf guard): only bundle-id matches survive. A boundary
    /// match that is (or is prefixed by) a sibling's bundle id is still excluded.
    public func userFiles(bundleID: String, appName: String, executable: String?,
                          appPath: String, allowNamePatterns: Bool = true,
                          siblingBundleIDs: [String] = []) -> [String] {
        var paths = Set<String>()
        let hasID = Self.isReverseDNS(bundleID)
        let ownedBySibling: (String) -> Bool = { token in
            siblingBundleIDs.contains { Self.containsBoundary(token, $0) }
        }

        // MARK: name-based fixed paths
        if allowNamePatterns, appName.count >= 2, Self.isUsableName(appName) {
            let variants = Self.nameVariants(appName).filter { Self.isUsableName($0) }
            for n in variants where n.count >= 2 {
                add(&paths, ["\(lib)/Application Support/\(n)", "\(lib)/Caches/\(n)",
                             "\(lib)/Logs/\(n)", "\(lib)/Preferences/\(n)",
                             "\(lib)/Preferences/\(n).plist",
                             "\(lib)/Saved Application State/\(n).savedState"])
            }
            // XDG dirs use lowercase spellings
            for n in variants where n.count >= 2 {
                let l = n.lowercased()
                add(&paths, ["\(home)/.config/\(l)", "\(home)/.cache/\(l)",
                             "\(home)/.local/share/\(l)"])
            }
        }

        // MARK: name ≥3 dynamic paths
        if allowNamePatterns, appName.count >= 3, Self.isUsableName(appName) {
            let crash = lib + "/Application Support/CrashReporter"
            let namePrefixes = Self.nameVariants(appName).filter { Self.isUsableName($0) }
            for f in children(crash)
            where f.hasSuffix(".plist") && namePrefixes.contains(where: { f.hasPrefix($0 + "_") }) {
                add(&paths, [crash + "/" + f])
            }
            let reports = lib + "/Logs/DiagnosticReports"
            // shared runtimes (Electron etc.) report under their own name for many apps,
            // so only the app name may match; either way a boundary is required
            let execShared = executable.map { Self.sharedRuntimeNames.contains($0.lowercased()) } ?? true
            let reportPrefixes = execShared ? [appName] : [appName, executable].compactMap { $0 }
            for f in children(reports)
            where reportPrefixes.contains(where: { Self.hasBoundaryPrefix(f, $0) }) {
                add(&paths, [reports + "/" + f])
            }
            // crash/updater framework leaves named after the app
            if !Self.commonWords.contains(appName.lowercased()) {
                add(&paths, ["\(lib)/Caches/SentryCrash/\(appName)", "\(lib)/Caches/KSCrash/\(appName)",
                             "\(lib)/Caches/\(appName)-updater",
                             "\(lib)/Application Support/Caches/\(appName)-updater"])
            }
        }

        // MARK: bundle-id fixed paths
        if hasID {
            let b = bundleID
            add(&paths, [
                "\(lib)/Application Support/\(b)", "\(lib)/Caches/\(b)", "\(lib)/Logs/\(b)",
                "\(lib)/Containers/\(b)", "\(lib)/WebKit/\(b)", "\(lib)/HTTPStorages/\(b)",
                "\(lib)/Application Scripts/\(b)", "\(lib)/Autosave Information/\(b)",
                "\(lib)/Preferences/\(b).plist", "\(lib)/Preferences/\(b)",
                "\(lib)/Saved Application State/\(b).savedState",
                "\(lib)/HTTPStorages/\(b).binarycookies", "\(lib)/Cookies/\(b).binarycookies",
                "\(lib)/WebKit/com.apple.WebKit.WebContent/\(b)",
                "\(lib)/Input Methods/\(b).app", "\(lib)/SyncedPreferences/\(b).plist",
                "\(lib)/Caches/\(b).ShipIt",
                "\(lib)/Caches/com.plausiblelabs.crashreporter.data/\(b)",
                "\(lib)/Caches/com.crashlytics.data/\(b)",
                "\(lib)/Application Support/com.bugsnag.Bugsnag/\(b)",
                "\(lib)/Caches/com.apple.nsurlsessiond/Downloads/\(b)",
                "\(lib)/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.ApplicationRecentDocuments/\(b).sfl2",
                "\(lib)/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.ApplicationRecentDocuments/\(b).sfl3",
                "\(lib)/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.ApplicationRecentDocuments/\(b).sfl4",
            ])
            if let cacheDir = darwinUserCacheDir() { add(&paths, [cacheDir + b]) }

            // boundary matches inside container dirs (app-extension ids); a match that
            // belongs to another installed app's bundle id is that app's leftover
            for dir in [lib + "/Group Containers", lib + "/Containers",
                        lib + "/Application Scripts", lib + "/Application Support/FileProvider"] {
                for child in children(dir)
                where Self.containsBoundary(child, b) && !ownedBySibling(child) {
                    add(&paths, [dir + "/" + child])
                }
            }
            // ByHost prefs: `$B.plist` or `$B.*.plist`
            let byHost = lib + "/Preferences/ByHost"
            for f in children(byHost)
            where f.hasSuffix(".plist") && (f == b + ".plist" || f.hasPrefix(b + "."))
                && !ownedBySibling((f as NSString).deletingPathExtension) {
                add(&paths, [byHost + "/" + f])
            }
            // UUID containers whose metadata pins this bundle id
            for child in children(lib + "/Containers")
            where child.count == 36 && child.filter({ $0 == "-" }).count == 4 {
                let plist = lib + "/Containers/\(child)/.com.apple.containermanagerd.metadata.plist"
                if plistValue(plist, key: "MCMMetadataIdentifier") == b {
                    add(&paths, [lib + "/Containers/\(child)"])
                }
            }
            // vendor nesting: `Application Support/<vendor>/<product>` etc. (com.<vendor>.<prod>)
            let comps = b.split(separator: ".").map(String.init)
            if comps.count >= 3, comps[1].count >= 3 {
                let product = comps[2...].joined(separator: ".")
                for base in [lib + "/Application Support", lib + "/Caches", lib + "/Logs"] {
                    add(&paths, ["\(base)/\(comps[1])/\(product)"])
                }
            }
            // bundle-leaf camelCase derivation ("AyuGramDesktop" → "AyuGram Desktop")
            if let leaf = comps.last, leaf.count >= 8, let derived = leafDerivedName(leaf, appName: appName) {
                add(&paths, ["\(lib)/Application Support/\(derived)", "\(lib)/Caches/\(derived)"])
            }
        }

        // MARK: LaunchAgents
        let agents = lib + "/LaunchAgents"
        for f in children(agents) where f.hasSuffix(".plist") && !f.hasPrefix("com.apple.") {
            let p = agents + "/" + f
            if hasID && (f == bundleID + ".plist" || f.hasPrefix(bundleID + ".")),
               !ownedBySibling((f as NSString).deletingPathExtension) {
                add(&paths, [p])
                continue
            }
            if allowNamePatterns, appName.count >= 5,
               !Self.commonWords.contains(appName.lowercased()), f.contains(appName) {
                add(&paths, [p])
                continue
            }
            if let program = launchAgentProgram(p),
               program == appPath || program.hasPrefix(appPath + "/") {
                add(&paths, [p])
            }
        }

        // MARK: NativeMessagingHosts pointing into the app bundle
        let appSupport = lib + "/Application Support"
        for host in children(appSupport) {
            let dir = appSupport + "/\(host)/NativeMessagingHosts"
            for f in children(dir) where f.hasSuffix(".json") {
                let p = dir + "/" + f
                if let target = nativeMessagingPath(p),
                   target == appPath || target.hasPrefix(appPath + "/") {
                    add(&paths, [p])
                }
            }
        }

        // Mole app_protection.sh: a normalized result equal to a Library/shared root is
        // never a leftover — names like "./" must not trash `~/Library/Preferences` itself
        let roots = PathPolicy.uninstallRoots(home: home)
        paths = paths.filter { !roots.contains(($0 as NSString).standardizingPath) }

        // independent CLI dotdirs never count as app leftovers
        let cliParents: Set<String> = [home, home + "/.config", home + "/.cache",
                                       home + "/.local/share"]
        paths = paths.filter { p in
            guard Self.cliDotdirNames.contains((p as NSString).lastPathComponent.lowercased())
            else { return true }
            return !cliParents.contains((p as NSString).deletingLastPathComponent)
        }
        // the Steam library is never a leftover
        let steam = lib + "/Application Support/Steam"
        paths.remove(steam)

        return paths.sorted()
    }

    /// Review-only /Library matches (Mole `find_app_system_files`). Listed but never deleted.
    public func systemFiles(bundleID: String, appName: String,
                            siblingBundleIDs: [String] = []) -> [String] {
        var paths = Set<String>()
        let hasID = Self.isReverseDNS(bundleID)
        let usableName = Self.isUsableName(appName)

        for base in ["/Library/Application Support", "/Library/Caches", "/Library/Logs"] {
            if appName.count >= 2, usableName { add(&paths, [base + "/" + appName]) }
            if hasID { add(&paths, [base + "/" + bundleID]) }
        }
        if appName.count >= 2, usableName {
            add(&paths, ["/Library/Preferences/" + appName, "/Library/Preferences/\(appName).plist"])
        }
        if hasID {
            let b = bundleID
            let ownedBySibling: (String) -> Bool = { token in
                siblingBundleIDs.contains { Self.containsBoundary(token, $0) }
            }
            add(&paths, ["/Library/Preferences/\(b).plist",
                         "/Library/LaunchAgents/\(b).plist", "/Library/LaunchDaemons/\(b).plist",
                         "/Library/Receipts/\(b).bom", "/Library/Receipts/\(b).plist"])
            for dir in ["/Library/LaunchAgents", "/Library/LaunchDaemons"] {
                for f in children(dir)
                where f.hasSuffix(".plist") && !f.hasPrefix("com.apple.") && f.hasPrefix(b + ".")
                    && !ownedBySibling((f as NSString).deletingPathExtension) {
                    add(&paths, [dir + "/" + f])
                }
            }
            for f in children("/Library/PrivilegedHelperTools")
            where !f.hasPrefix("com.apple.") && (f == b || f.hasPrefix(b + "."))
                && !ownedBySibling(f) {
                add(&paths, ["/Library/PrivilegedHelperTools/" + f])
            }
            for f in children("/private/var/db/receipts") where f.hasPrefix(b) {
                add(&paths, ["/private/var/db/receipts/" + f])
            }
            let comps = b.split(separator: ".").map(String.init)
            if comps.count >= 3, comps[1].count >= 3 {
                let product = comps[2...].joined(separator: ".")
                for base in ["/Library/Application Support", "/Library/Caches", "/Library/Logs"] {
                    add(&paths, ["\(base)/\(comps[1])/\(product)"])
                }
            }
        }
        if appName.count >= 5, usableName, !Self.commonWords.contains(appName.lowercased()) {
            for dir in ["/Library/LaunchAgents", "/Library/LaunchDaemons"] {
                for f in children(dir)
                where f.hasSuffix(".plist") && !f.hasPrefix("com.apple.") && f.contains(appName) {
                    add(&paths, [dir + "/" + f])
                }
            }
        }
        return paths.sorted()
    }

    // MARK: helpers

    private func plistValue(_ path: String, key: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    /// `Program` or `ProgramArguments[0]` of a LaunchAgent plist; nil unless absolute and real.
    private func launchAgentProgram(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        var program = obj["Program"] as? String
        if program == nil, let args = obj["ProgramArguments"] as? [Any] {
            program = args.first as? String
        }
        guard let p = program, p.hasPrefix("/"), FileStat.exists(p) else { return nil }
        return p
    }

    /// `path` field of a NativeMessagingHosts manifest (≤64KB regular files only).
    private func nativeMessagingPath(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 64 * 1024,
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = obj["path"] as? String, p.hasPrefix("/") else { return nil }
        return p
    }

    /// Mole bundle-leaf derivation: camelCase leaf like `AyuGramDesktop` for app "AyuGram"
    /// yields "AyuGram Desktop" (only when it starts with the no-space display name and
    /// continues at a capital/digit boundary).
    private func leafDerivedName(_ leaf: String, appName: String) -> String? {
        let head = appName.replacingOccurrences(of: " ", with: "")
        guard leaf.hasPrefix(head), leaf.count > head.count else { return nil }
        let rest = leaf.dropFirst(head.count)
        guard let first = rest.first, first.isUppercase || first.isNumber else { return nil }
        return head + " " + rest
    }
}
