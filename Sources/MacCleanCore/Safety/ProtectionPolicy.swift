import Foundation

/// Port of Mole `lib/core/app_protection.sh` (clean mode): `should_protect_data`,
/// `should_protect_path`, `holds_compiled_model_cache`, `is_endpoint_security_cache_path`.
public struct ProtectionPolicy: Sendable {
    public let home: String
    /// Our own log directory, protected like Mole protects `~/Library/Logs/mole`.
    public let ownLogDirectory: String

    public init(home: String, ownLogDirectory: String) {
        self.home = home
        self.ownLogDirectory = ownLogDirectory
    }

    static let cleanProtectedGlobs = ProtectionData.systemCriticalBundles + ProtectionData.dataProtectedBundles

    // MARK: should_protect_data (app_protection.sh:199)

    private static let dataFastPatterns: [String] = [
        "com.apple.*", "loginwindow", "dock", "systempreferences", "finder", "safari",
        "org.cups.*",
        "backgroundtaskmanagement*", "keychain*", "security*", "bluetooth*", "wifi*", "network*", "tcc",
        "notification*", "accessibility*", "universalaccess*", "HIToolbox*",
        "*inputmethod*", "*InputMethod*", "*IME", "textinput*", "TextInput*",
        "keyboard*", "Keyboard*", "inputsource*", "InputSource*", "keylayout*", "KeyLayout*",
        "GlobalPreferences", ".GlobalPreferences", "org.pqrs.Karabiner*",
        "com.1password.*", "com.agilebits.*", "com.lastpass.*", "com.dashlane.*", "com.bitwarden.*",
        "com.jetbrains.*", "JetBrains*", "com.microsoft.*", "com.visualstudio.*",
        "com.sublimetext.*", "com.sublimehq.*", "Cursor", "Claude", "ChatGPT", "com.openai.codex", "Codex",
        "codex-runtimes", "Ollama",
        "com.clash.app", "com.nssurge.*", "com.v2ray.*", "com.clash.*", "ClashX*", "Surge*", "Shadowrocket*",
        "Quantumult*",
        "clash-*", "Clash-*", "*-clash", "*-Clash", "clash.*", "Clash.*", "clash_*", "*clash-verge*",
        "*Clash-Verge*", "clashverge*", "ClashVerge*",
        "com.docker.*", "com.getpostman.*", "com.insomnia.*",
    ]

    public func shouldProtectData(_ bundleID: String) -> Bool {
        if Glob.matchesAny(Self.dataFastPatterns, bundleID) { return true }
        return Glob.matchesAny(ProtectionData.dataProtectedBundles, bundleID)
    }

    // MARK: helpers

    public static func holdsCompiledModelCache(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed.hasSuffix("/com.apple.e5rt.e5bundlecache") { return true }
        return FileStat.isDirectory(trimmed + "/com.apple.e5rt.e5bundlecache")
    }

    public static func isEndpointSecurityCachePath(_ path: String) -> Bool {
        guard path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/") else { return false }
        let lower = path.lowercased()
        return ProtectionData.endpointSecurityBundlePrefixes.contains { lower.contains($0.lowercased()) }
    }

    private func isSharedHomeStateRoot(_ path: String) -> Bool {
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        let ci: Set<String> = [".cache", ".config", ".local", ".local/bin", ".local/lib", ".local/share", ".local/state"]
        if p.hasPrefix(home + "/") {
            let rel = String(p.dropFirst(home.count + 1)).lowercased()
            if ci.contains(rel) { return true }
        }
        return p == home + "/Library/Unity" || p == home + "/Library/Application Support/Epic"
    }

    private func isOrbStackRuntimePath(_ path: String) -> Bool {
        Glob.matchesAny(["*/Group Containers/*dev.orbstack", "*/Group Containers/*dev.orbstack/*",
                         "*/.orbstack", "*/.orbstack/*"], path)
    }

    private func isWeChatWebProfileCacheChild(_ path: String) -> Bool {
        let root = home + "/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/web/profiles/"
        guard path.hasPrefix(root) else { return false }
        let rel = String(path.dropFirst(root.count))
        guard let slash = rel.firstIndex(of: "/"), slash != rel.startIndex else { return false }
        let rest = String(rel[rel.index(after: slash)...])
        return Glob.match("Cache/?*", rest) || Glob.match("Service Worker/CacheStorage/?*", rest)
    }

    // MARK: should_protect_path (clean mode, app_protection.sh:406-681)

    public func shouldProtectPath(_ path: String) -> Bool {
        if path.isEmpty { return false }
        let h = home

        // clean-only user state
        if Glob.matchesAny([
            "\(h)/.prometheus/data", "\(h)/.prometheus/data/*", "\(h)/.jupyter/runtime", "\(h)/.jupyter/runtime/*",
            "\(h)/.yarn/berry/cache", "\(h)/.yarn/berry/cache/*", "\(h)/.gitconfig.lock", "\(h)/.gitconfig.bak*",
            "\(h)/.config/fish/fish_history.bak*", "\(h)/.bash_history.bak*", "\(h)/.zsh_history.bak*",
        ], path) { return true }

        if isSharedHomeStateRoot(path) { return true }

        let codexRoot = "\(h)/Library/Caches/Codex/"
        let knownRebuildable = [
            "Default/Cache/", "Default/Code Cache/", "Default/Partitions/codex-browser-app/Cache/",
            "Default/Partitions/codex-browser-app/Code Cache/", "codex-browser-app/Cache/", "codex-browser-app/Code Cache/",
        ].contains { path.hasPrefix(codexRoot + $0) }

        if isOrbStackRuntimePath(path) { return true }

        if Glob.matchesAny([
            "*[Ss]ystem[Ss]ettings*", "*[Ss]ystem[Pp]references*", "*[Cc]ontrol[Cc]enter*",
            "*com.apple.[Ss]ettings*", "*com.apple.[Ss]ETTINGS*", "*com.apple.[Nn]otes*", "*com.apple.[Nn]OTES*",
            "*com.apple.systempreferences.cache*", "*com.apple.Settings.cache*", "*com.apple.controlcenter.cache*",
            "*com.apple.finder.cache*", "*com.apple.dock.cache*",
            "*/Library/Containers/com.apple.Settings*", "*/Library/Containers/com.apple.SystemSettings*",
            "*/Library/Containers/com.apple.controlcenter*",
            "*/Library/Group Containers/com.apple.systempreferences*", "*/Library/Group Containers/com.apple.Settings*",
            "*/com.apple.sharedfilelist/*com.apple.Settings*", "*/com.apple.sharedfilelist/*com.apple.SystemSettings*",
            "*/com.apple.sharedfilelist/*systempreferences*",
        ], path) { return true }

        var containerCachePath = false
        if let bundleID = Self.containerBundleID(path) {
            if Glob.matchesAny(["*/Data/Library/Caches/*", "*/Data/tmp/*",
                                "\(h)/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/log/*",
                                "\(h)/Library/Containers/com.tencent.xinWeChat/Data/.wxapplet/WMPF/*"], path)
                || isWeChatWebProfileCacheChild(path) {
                containerCachePath = true
            } else if shouldProtectData(bundleID) {
                return true
            }
        }

        if Glob.matchesAny(["*com.apple.Settings*", "*com.apple.SystemSettings*", "*com.apple.controlcenter*",
                            "*com.apple.finder*", "*com.apple.dock*"], path) { return true }

        if Self.isEndpointSecurityCachePath(path) { return true }

        let own = ownLogDirectory
        if path == own || path == own + "/" || path.hasPrefix(own + "/") { return true }

        // Codex crash pending: deeper than one level → protect; exactly one level → allowed (falls through).
        if Glob.match("*/Library/Application Support/Codex/Crashpad/pending/*/*", path) { return true }
        let codexPendingTopLevel = Glob.match("*/Library/Application Support/Codex/Crashpad/pending/?*", path)

        if !codexPendingTopLevel && Glob.matchesAny(Self.protectedPathPatterns, path) { return true }

        if !containerCachePath && !knownRebuildable {
            if Glob.matchesAny(Self.cleanProtectedGlobs, path) { return true }
            let filename = (path as NSString).lastPathComponent
            if shouldProtectData(filename) { return true }
        }
        return false
    }

    static func containerBundleID(_ path: String) -> String? {
        for marker in ["/Library/Containers/", "/Library/Group Containers/"] {
            if let r = path.range(of: marker) {
                let rest = path[r.upperBound...]
                let id = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                if !id.isEmpty { return id }
            }
        }
        return nil
    }

    static let protectedPathPatterns: [String] = [
        "*/Library/Preferences/com.apple.dock.plist", "*/Library/Preferences/com.apple.finder.plist",
        "*/Library/Logs/mole", "*/Library/Logs/mole/", "*/Library/Logs/mole/*",
        "*/Library/Application Support/Codex", "*/Library/Application Support/Codex/*",
        "*/Library/Logs/com.openai.codex", "*/Library/Logs/com.openai.codex/*",
        "*/.codex/sessions", "*/.codex/sessions/*", "*/.codex/auth.json", "*/.codex/history.jsonl",
        "*/.codex/state_*.sqlite", "*/.codex/logs_*.sqlite", "*/.codex/session_index.jsonl",
        "*/.codex/cache/session_index.jsonl", "*/.codex/cache/codex_app_directory", "*/.codex/cache/codex_app_directory/*",
        "*/ByHost/com.apple.bluetooth.*", "*/ByHost/com.apple.wifi.*",
        "*/Library/Preferences/com.apple.networkextension*.plist",
        "*/Library/Mobile Documents*", "*/Mobile Documents*",
        "*/Library/Accounts", "*/Library/Accounts/*", "*/Library/Keychains", "*/Library/Keychains/*",
        "*/Library/Mail", "*/Library/Mail/*", "*/Library/Calendars", "*/Library/Calendars/*",
        "*/Library/Contacts", "*/Library/Contacts/*",
        "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/Components/*",
        "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST/*",
        "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/VST3/*",
        "/Library/Application Support/iZotope", "/Library/Application Support/iZotope/*",
        "*/Library/Application Support/iZotope", "*/Library/Application Support/iZotope/*",
        "/Library/Application Support/LaserSoft Imaging", "/Library/Application Support/LaserSoft Imaging/*",
        "*/Library/Preferences/com.native-instruments*", "*/Library/Preferences/com.avid.mediacomposer*.plist",
        "*/Library/Preferences/com.fabfilter.*.[0-9].plist", "*/Library/Preferences/com.fabfilter.*.[0-9][0-9].plist",
        "*/Library/Preferences/com.paceap.*.plist",
        "/private/var/folders/*/C/com.native-instruments*", "/private/var/folders/*/C/com.avid.mediacomposer*",
        "/private/var/folders/*/C/com.paceap.eden.iLokLicenseManager*",
        "*/Library/Caches/ms-playwright", "*/Library/Caches/ms-playwright/*",
        "*/Library/Caches/camoufox", "*/Library/Caches/camoufox/*",
        "*/Library/Caches/Cypress", "*/Library/Caches/Cypress/*",
        "*/Library/Caches/app.cotypist.Cotypist", "*/Library/Caches/app.cotypist.Cotypist/*",
        "*/Library/Caches/com.displaylink.DisplayLinkUserAgent", "*/Library/Caches/com.displaylink.DisplayLinkUserAgent/*",
        "*/Library/Caches/com.lasersoft-imaging.SilverFast9", "*/Library/Caches/com.lasersoft-imaging.SilverFast9/*",
        "*/Library/Caches/com.lasersoft-imaging.SilverFast-9-Installer",
        "*/Library/Caches/com.lasersoft-imaging.SilverFast-9-Installer/*",
        "*/Library/Caches/Adobe *", "*/Library/Caches/* Adobe*",
        "*/Library/Caches/com.apple.containermanagerd", "*/Library/Caches/com.apple.containermanagerd/*",
        "*/Library/Caches/com.apple.homed", "*/Library/Caches/com.apple.homed/*",
        "*/Library/Caches/com.apple.ap.adprivacyd", "*/Library/Caches/com.apple.ap.adprivacyd/*",
        "*/Library/Caches/FamilyCircle", "*/Library/Caches/FamilyCircle/*",
        "*/Library/Caches/com.apple.HomeKit", "*/Library/Caches/com.apple.HomeKit/*",
        "*/Library/Caches/com.apple.WorkflowKit.BackgroundShortcutRunner.ShortcutsSandboxCache",
        "*/Library/Caches/com.apple.WorkflowKit.BackgroundShortcutRunner.ShortcutsSandboxCache/*",
        "*/Library/Caches/com.apple.siriactionsd.ShortcutsSandboxCache",
        "*/Library/Caches/com.apple.siriactionsd.ShortcutsSandboxCache/*",
        "*/Library/Caches/GIPPseudonymousID", "*/Library/Caches/GIPPseudonymousID/*",
        "*/Library/Caches/CCTClearcutLogger", "*/Library/Caches/CCTClearcutLogger/*",
        "*/Library/Application Support/com.apple.idleassetsd", "*/Library/Application Support/com.apple.idleassetsd/*",
        "*/Library/Application Support/com.apple.wallpaper", "*/Library/Application Support/com.apple.wallpaper/*",
        "*com.apple.coreaudio*", "*com.apple.audio.*", "*coreaudiod*",
    ]
}
