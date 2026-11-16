import Foundation

public enum CleanSection: String, CaseIterable, Sendable, Identifiable {
    case userEssentials = "User essentials"
    case appCaches = "App caches"
    case browsers = "Browsers"
    case developerTools = "Developer tools"
    case apps = "Apps & utilities"

    public var id: String { rawValue }
}

/// "Only clean while none of these is running" guard (Mole `pgrep` three-state probe).
public struct RunningGuard: Sendable {
    public let bundleIDs: [String]
    public let names: [String]

    public init(bundleIDs: [String] = [], names: [String] = []) {
        self.bundleIDs = bundleIDs
        self.names = names
    }
}

/// One catalog row. Patterns start with `~` and may contain glob components;
/// each match is one deletion candidate (`/*` = the directory's children, Mole convention).
public struct CleanRule: Sendable, Identifiable {
    public var id: String { section.rawValue + "/" + label }
    public let section: CleanSection
    public let label: String
    public let patterns: [String]
    public var excludeNames: [String] = []
    public var minAgeDays: Double?
    public var whenNotRunning: RunningGuard?
    /// Mole sweep of sandbox containers: skip bundles protected by `should_protect_data`.
    public var skipProtectedContainerOwners = false
    public var source: String

    public init(_ section: CleanSection, _ label: String, _ patterns: [String], source: String,
                excludeNames: [String] = [], minAgeDays: Double? = nil, whenNotRunning: RunningGuard? = nil,
                skipProtectedContainerOwners: Bool = false) {
        self.section = section
        self.label = label
        self.patterns = patterns
        self.source = source
        self.excludeNames = excludeNames
        self.minAgeDays = minAgeDays
        self.whenNotRunning = whenNotRunning
        self.skipProtectedContainerOwners = skipProtectedContainerOwners
    }
}

/// User-area subset of Mole `mo clean` (docs/analysis/01-clean.md §2.2–2.7). No sudo, no owner commands.
public enum CleanCatalog {
    static let chromiumLeaves = ["Application Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache",
                                 "GraphiteDawnCache"]
    static let chromiumRootLeaves = ["component_crx_cache", "ShaderCache", "GrShaderCache", "GraphiteDawnCache",
                                     "Crashpad/completed"]

    static func chromium(_ base: String) -> [String] {
        chromiumLeaves.map { "\(base)/*/\($0)/*" } + chromiumRootLeaves.map { "\(base)/\($0)/*" }
    }

    /// `getconf DARWIN_USER_CACHE_DIR` (e.g. /var/folders/xx/yy/C), without the trailing slash.
    static let darwinUserCacheDir: String = {
        guard let path = DarwinDirs.userCacheDir() else { return "/nonexistent" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return FileStat.realPath(trimmed) ?? trimmed
    }()

    public static let rules: [CleanRule] = [
        // 2.2 User essentials (user.sh:224-362)
        CleanRule(.userEssentials, "User app cache", ["~/Library/Caches/*"], source: "user.sh:267-330",
                  excludeNames: ["Google", "deno"]),
        CleanRule(.userEssentials, "User app logs", ["~/Library/Logs/*"], source: "user.sh:224-262"),
        CleanRule(.userEssentials, "Trash", ["~/.Trash/*"], source: "user.sh:42-173"),
        CleanRule(.userEssentials, "Recent items", [
            "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentApplications.sfl*",
            "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl*",
            "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentServers.sfl*",
            "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentHosts.sfl*",
            "~/Library/Preferences/com.apple.recentitems.plist",
        ], source: "user.sh:345-362"),

        // 2.3 App caches (user.sh:1250-1716)
        CleanRule(.appCaches, "Saved application state", ["~/Library/Saved Application State/*"],
                  source: "user.sh:1257"),
        CleanRule(.appCaches, "Apple system caches", [
            "~/Library/Caches/com.apple.WebKit.Networking/*", "~/Library/Caches/com.apple.QuickLook.thumbnailcache",
            "~/Library/Caches/Quick Look/*", "~/Library/Caches/com.apple.helpd/*",
            "~/Library/Caches/com.apple.AppleMediaServices/*", "~/Library/Caches/com.apple.duetexpertd/*",
            "~/Library/Caches/com.apple.parsecd/*", "~/Library/Caches/com.apple.python/*",
            "~/Library/Caches/GeoServices/*",
        ], source: "user.sh:1258-1308"),
        CleanRule(.appCaches, "Diagnostic reports", ["~/Library/DiagnosticReports/*"], source: "user.sh:1261"),
        CleanRule(.appCaches, "Incomplete downloads",
                  ["~/Downloads/*.download", "~/Downloads/*.crdownload", "~/Downloads/*.part"],
                  source: "user.sh:365-440"),
        CleanRule(.appCaches, "Identity & suggestions caches", [
            "~/Library/IdentityCaches/*", "~/Library/Suggestions/*",
            "~/Library/Application Support/AddressBook/Sources/*/Photos.cache",
        ], source: "user.sh:1268-1274"),
        CleanRule(.appCaches, "Crash reporter", ["~/Library/Application Support/CrashReporter/*"],
                  source: "user.sh:1071-1080", minAgeDays: 30),
        CleanRule(.appCaches, "Apple container caches", [
            "~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/*",
            "~/Library/Containers/com.apple.AppStore/Data/Library/Caches/*",
            "~/Library/Containers/com.apple.stocks/Data/Library/Caches/*",
            "~/Library/Containers/com.apple.AMPArtworkAgent/Data/Library/Caches/*",
            "~/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/*",
            "~/Library/Containers/com.apple.mediaanalysisd/Data/tmp/*",
            "~/Library/Containers/com.apple.geod/Data/tmp/*",
        ], source: "user.sh:1286-1303"),
        CleanRule(.appCaches, "Sandboxed app caches", ["~/Library/Containers/*/Data/Library/Caches/*"],
                  source: "user.sh:1312-1518", skipProtectedContainerOwners: true),
        CleanRule(.appCaches, "Group container logs", [
            "~/Library/Group Containers/*/Logs/*", "~/Library/Group Containers/*/Library/Logs/*",
        ], source: "user.sh:1520-1716", skipProtectedContainerOwners: true),
        CleanRule(.appCaches, "Handoff clipboard", [
            "~/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/*",
        ], source: "user.sh:1369-1420", minAgeDays: 1.0 / 24),

        // 2.4 Browsers (user.sh:2059-2310)
        CleanRule(.browsers, "Safari cache", ["~/Library/Caches/com.apple.Safari/*"], source: "user.sh:2062"),
        CleanRule(.browsers, "Chrome cache", chromium("~/Library/Application Support/Google/Chrome") + [
            "~/Library/Caches/Google/Chrome/*",
        ], source: "user.sh:838-866, 2066-2108",
           whenNotRunning: RunningGuard(bundleIDs: ["com.google.Chrome"], names: ["Google Chrome"])),
        CleanRule(.browsers, "Edge cache", chromium("~/Library/Application Support/Microsoft Edge"),
                  source: "user.sh:2113",
                  whenNotRunning: RunningGuard(bundleIDs: ["com.microsoft.edgemac"], names: ["Microsoft Edge"])),
        CleanRule(.browsers, "Brave cache", chromium("~/Library/Application Support/BraveSoftware/Brave-Browser"),
                  source: "user.sh:2188-2212",
                  whenNotRunning: RunningGuard(bundleIDs: ["com.brave.Browser"], names: ["Brave Browser"])),
        CleanRule(.browsers, "Arc cache", chromium("~/Library/Application Support/Arc/User Data"),
                  source: "user.sh:2114-2150",
                  whenNotRunning: RunningGuard(bundleIDs: ["company.thebrowser.Browser"], names: ["Arc"])),
        CleanRule(.browsers, "Firefox cache", ["~/Library/Application Support/Firefox/Profiles/*/cache2/*"],
                  source: "user.sh:869-874, 2230-2246",
                  whenNotRunning: RunningGuard(bundleIDs: ["org.mozilla.firefox"], names: ["firefox"])),

        // 2.6 Developer tools (dev.sh) — direct-delete rows only
        CleanRule(.developerTools, "npm cache", ["~/.npm/_cacache/*", "~/.npm/_logs/*", "~/.npm/_prebuilds/*"],
                  source: "dev.sh:681-707"),
        CleanRule(.developerTools, "Python caches", [
            "~/.pyenv/cache/*", "~/.cache/poetry/*", "~/.cache/ruff/*", "~/.cache/mypy/*", "~/.pytest_cache/*",
        ], source: "dev.sh:956-970"),
        CleanRule(.developerTools, "Cargo registry cache", ["~/.cargo/registry/cache/*", "~/.rustup/downloads/*"],
                  source: "dev.sh:1381-1440", whenNotRunning: RunningGuard(names: ["cargo", "rustc"])),
        CleanRule(.developerTools, "Ruby caches", [
            "~/.rbenv/cache/*", "~/.gem/specs/*", "~/.gem/ruby/*/cache/*.gem", "~/.bundle/cache/*",
        ], source: "dev.sh:1443-1447"),
        CleanRule(.developerTools, "Container & cloud CLI caches", [
            "~/.docker/buildx/cache/*", "~/.kube/cache/*", "~/.aws/cli/cache/*", "~/.config/gcloud/logs/*",
            "~/.azure/logs/*",
        ], source: "dev.sh:1692-1711"),
        CleanRule(.developerTools, "Frontend tool caches", [
            "~/.cache/typescript/*", "~/.cache/electron/*", "~/.cache/node-gyp/*", "~/.cache/vite/*",
            "~/.cache/webpack/*", "~/.cache/eslint/*", "~/.cache/prettier/*", "~/.node-gyp/*", "~/.turbo/cache/*",
            "~/.vite/cache/*", "~/.parcel-cache/*",
        ], source: "dev.sh:1713-1725"),
        CleanRule(.developerTools, "Shell caches", ["~/.oh-my-zsh/cache/*", "~/.cache/pre-commit/*"],
                  source: "dev.sh:6217-6222"),
        CleanRule(.developerTools, "Xcode DerivedData", ["~/Library/Developer/Xcode/DerivedData/*"],
                  source: "app_caches.sh:215-397",
                  whenNotRunning: RunningGuard(bundleIDs: ["com.apple.dt.Xcode"],
                                               names: ["Xcode", "xcodebuild", "xctest", "XCBBuildService",
                                                       "swift-frontend"])),
        CleanRule(.developerTools, "Xcode caches & products", [
            "~/Library/Caches/com.apple.dt.Xcode/*", "~/Library/Developer/Xcode/Products/*",
            "~/Library/Developer/Xcode/UserData/IB Support/*",
        ], source: "app_caches.sh:475-525, dev.sh:3255",
           whenNotRunning: RunningGuard(bundleIDs: ["com.apple.dt.Xcode"],
                                        names: ["Xcode", "xcodebuild", "xctest", "XCBBuildService", "swift-frontend"])),
        CleanRule(.developerTools, "Simulator caches & logs", [
            "~/Library/Developer/CoreSimulator/Caches/*", "~/Library/Logs/CoreSimulator/*",
        ], source: "app_caches.sh:410-460",
           whenNotRunning: RunningGuard(bundleIDs: ["com.apple.iphonesimulator"], names: ["Simulator"])),
        CleanRule(.developerTools, "Swift & Android build caches", [
            "~/.cache/swift-package-manager/*", "~/.android/build-cache/*", "~/.android/cache/*",
        ], source: "dev.sh:3250-3261"),
        CleanRule(.developerTools, "CPAN build artifacts", ["~/.cpan/build/*"], source: "dev.sh:1450-1454"),
        CleanRule(.developerTools, "Clang module cache", [darwinUserCacheDir + "/clang/*"], source: "dev.sh:904-944",
                  whenNotRunning: RunningGuard(bundleIDs: ["com.apple.dt.Xcode"],
                                               names: ["Xcode", "xcodebuild", "clang", "swift-frontend"])),
        CleanRule(.developerTools, "Other toolchain caches", [
            "~/.composer/cache/*", "~/.cache/bazel/*", "~/.cache/zig/*", "~/.cache/terraform/*",
            "~/.cache/prisma/*", "~/.hex/cache/*", "~/.opam/download-cache/*",
        ], source: "dev.sh:4405-4432, 6173, 6232"),

        // 2.6.10 / 2.7 Apps
        CleanRule(.apps, "VS Code caches", [
            "~/Library/Application Support/Code/logs/*", "~/Library/Application Support/Code/Cache/*",
            "~/Library/Application Support/Code/CachedExtensionVSIXs/*",
            "~/Library/Application Support/Code/CachedData/*",
        ], source: "app_caches.sh:589-672",
           whenNotRunning: RunningGuard(bundleIDs: ["com.microsoft.VSCode"], names: ["Code", "Electron"])),
        CleanRule(.apps, "Shell history temp files", ["~/.zcompdump*", "~/.lesshst", "~/.viminfo.tmp", "~/.wget-hsts"],
                  source: "app_caches.sh:2168-2179"),
        CleanRule(.apps, "Chat app caches", [
            "~/Library/Application Support/discord/Cache/*", "~/Library/Application Support/Slack/Cache/*",
        ], source: "app_caches.sh:1106-1140",
           whenNotRunning: RunningGuard(bundleIDs: ["com.hnc.Discord", "com.tinyspeck.slackmacgap"],
                                        names: ["Discord", "Slack"])),
    ]
}
