import Foundation
import Testing
@testable import MacCleanCore

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "macclean-uninstall-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private let idleProbes = ProbeContext(
    processes: ProcessSnapshot(entries: [], bundleIDs: [], complete: true),
    openFiles: OpenFilesSnapshot(paths: [], complete: true)
)

private func touch(_ path: String) throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(count: 8).write(to: URL(fileURLWithPath: path))
}

private func mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func writeApp(at appsDir: String, name: String, bundleID: String,
                      version: String = "1.0", executable: String? = nil) throws {
    let contents = appsDir + "/" + name + ".app/Contents"
    try mkdir(contents + "/MacOS")
    var info: [String: Any] = ["CFBundleIdentifier": bundleID,
                               "CFBundleShortVersionString": version,
                               "CFBundleName": name]
    if let executable {
        info["CFBundleExecutable"] = executable
        try Data(count: 8).write(to: URL(fileURLWithPath: contents + "/MacOS/" + executable))
    }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: URL(fileURLWithPath: contents + "/Info.plist"))
}

private func makeDeleter(home: String) -> SafeDeleter {
    let protection = ProtectionPolicy(home: home, ownLogDirectory: home + "/Library/Logs/MacClean")
    return SafeDeleter(policy: PathPolicy(home: home, protection: protection),
                       whitelist: Whitelist(expandedPatterns: []), log: nil)
}

@Suite struct LeftoverFinderTests {
    private func findFoo(home: String, allowNames: Bool = true) -> [String] {
        LeftoverFinder(home: home)
            .userFiles(bundleID: "com.example.Foo", appName: "Foo", executable: "FooExec",
                       appPath: "/tmp/Foo.app", allowNamePatterns: allowNames)
    }

    @Test func findsBundleIDAndNameLeftovers() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lib = home + "/Library"
        try touch(lib + "/Preferences/com.example.Foo.plist")
        try touch(lib + "/Preferences/Foo.plist")
        try mkdir(lib + "/Caches/com.example.Foo")
        try mkdir(lib + "/Application Support/com.example.Foo")
        try mkdir(lib + "/Application Support/Foo")
        try mkdir(lib + "/Containers/com.example.Foo")
        try mkdir(lib + "/Group Containers/com.example.Foo.group")
        try mkdir(lib + "/Containers/com.example.Foo-Helper")
        try mkdir(lib + "/Saved Application State/com.example.Foo.savedState")
        try touch(lib + "/LaunchAgents/com.example.Foo.helper.plist")
        try touch(lib + "/Preferences/ByHost/com.example.Foo.ABCDEF.plist")
        try touch(lib + "/HTTPStorages/com.example.Foo.binarycookies")
        try mkdir(lib + "/Logs/Foo")

        let found = findFoo(home: home)
        for expected in ["/Preferences/com.example.Foo.plist", "/Preferences/Foo.plist",
                         "/Caches/com.example.Foo", "/Application Support/com.example.Foo",
                         "/Application Support/Foo", "/Containers/com.example.Foo",
                         "/Group Containers/com.example.Foo.group",
                         "/Containers/com.example.Foo-Helper",
                         "/Saved Application State/com.example.Foo.savedState",
                         "/LaunchAgents/com.example.Foo.helper.plist",
                         "/Preferences/ByHost/com.example.Foo.ABCDEF.plist",
                         "/HTTPStorages/com.example.Foo.binarycookies", "/Logs/Foo"] {
            #expect(found.contains(lib + expected), "missing \(expected)")
        }
    }

    @Test func doesNotMatchFooBarOrUnrelated() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lib = home + "/Library"
        try touch(lib + "/Preferences/com.example.Foo.plist")
        // FooBar leftovers must not be attributed to Foo
        try touch(lib + "/Preferences/com.example.FooBar.plist")
        try mkdir(lib + "/Caches/com.example.FooBar")
        try mkdir(lib + "/Containers/com.example.FooBar")
        try mkdir(lib + "/Application Support/FooBar")
        // an unrelated app entirely
        try mkdir(lib + "/Caches/com.other.Bar")
        try touch(lib + "/Preferences/com.other.Bar.plist")

        let found = findFoo(home: home)
        #expect(found == [lib + "/Preferences/com.example.Foo.plist"])
    }

    @Test func siblingDisablesNameMatching() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lib = home + "/Library"
        try mkdir(lib + "/Caches/com.example.Foo")
        try mkdir(lib + "/Application Support/Foo")
        try touch(lib + "/Preferences/Foo.plist")

        let found = findFoo(home: home, allowNames: false)
        #expect(found == [lib + "/Caches/com.example.Foo"])
    }

    @Test func cliDotdirsAreNotLeftovers() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try mkdir(home + "/.config/claude")
        let found = LeftoverFinder(home: home)
            .userFiles(bundleID: "com.example.claudeapp", appName: "Claude", executable: nil,
                       appPath: "/tmp/Claude.app")
        #expect(!found.contains(home + "/.config/claude"))
    }

    @Test func slashAndDotNamesNeverProduceLibraryRoots() throws {
        // S1: names like "./" make `~/Library/Preferences/./` normalize to the root itself
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lib = home + "/Library"
        try mkdir(lib + "/Preferences")
        try mkdir(lib + "/Caches")
        try mkdir(lib + "/Application Support")
        for name in ["./", "/.", "..", "..."] {
            let found = LeftoverFinder(home: home)
                .userFiles(bundleID: "", appName: name, executable: nil, appPath: "/tmp/x.app")
            #expect(found.isEmpty, "name \(name) produced \(found)")
        }
    }

    @Test func siblingBundleIDContainerNotClaimed() throws {
        // U1: com.jetbrains.intellij must not claim Containers/com.jetbrains.intellij.ce
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lib = home + "/Library"
        try mkdir(lib + "/Containers/com.jetbrains.intellij")
        try mkdir(lib + "/Containers/com.jetbrains.intellij.ce")
        let found = LeftoverFinder(home: home)
            .userFiles(bundleID: "com.jetbrains.intellij", appName: "IntelliJ",
                       executable: nil, appPath: "/tmp/IntelliJ.app",
                       siblingBundleIDs: ["com.jetbrains.intellij.ce"])
        #expect(found.contains(lib + "/Containers/com.jetbrains.intellij"))
        #expect(!found.contains(lib + "/Containers/com.jetbrains.intellij.ce"))
    }

    @Test func diagnosticReportsBoundaryAndSharedRuntime() throws {
        // U5: prefix must end at a boundary; a shared-runtime executable matches by app name only
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let reports = home + "/Library/Logs/DiagnosticReports"
        try touch(reports + "/Foo_2024.ips")
        try touch(reports + "/FooBar_2024.ips")
        try touch(reports + "/Electron_2024.ips")
        try touch(reports + "/ElectronHelper_x.ips")

        let found = LeftoverFinder(home: home)
            .userFiles(bundleID: "com.example.Foo", appName: "Foo", executable: "Electron",
                       appPath: "/tmp/Foo.app")
        #expect(found.contains(reports + "/Foo_2024.ips"))
        #expect(!found.contains(reports + "/FooBar_2024.ips"))
        #expect(!found.contains(reports + "/Electron_2024.ips"))
        #expect(!found.contains(reports + "/ElectronHelper_x.ips"))

        // a normal (non-runtime) executable still matches at a boundary
        let found2 = LeftoverFinder(home: home)
            .userFiles(bundleID: "com.example.Zed", appName: "Zed", executable: "FooBar",
                       appPath: "/tmp/Zed.app")
        #expect(found2.contains(reports + "/FooBar_2024.ips"))
    }

    @Test func launchAgentMatchedByProgramInsideBundle() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let appPath = home + "/Applications/Foo.app"
        try mkdir(appPath + "/Contents/MacOS")
        try Data(count: 8).write(to: URL(fileURLWithPath: appPath + "/Contents/MacOS/FooExec"))
        let plist = home + "/Library/LaunchAgents/com.vendor.helper.plist"
        try touch(plist)
        try PropertyListSerialization.data(
            fromPropertyList: ["ProgramArguments": [appPath + "/Contents/MacOS/FooExec", "--quiet"]],
            format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: plist))

        let found = LeftoverFinder(home: home)
            .userFiles(bundleID: "com.example.Foo", appName: "Foo", executable: "FooExec",
                       appPath: appPath)
        #expect(found.contains(plist))
    }
}

@Suite struct AppInventoryTests {
    @Test func findsAppsAndReadsMetadata() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.example.Foo",
                     version: "2.5", executable: "FooExec")

        let apps = AppInventory(roots: [appsDir])
            .scan(protection: ProtectionPolicy(home: home, ownLogDirectory: ""))
        let app = try #require(apps.first)
        #expect(apps.count == 1)
        #expect(app.name == "Foo")
        #expect(app.bundleID == "com.example.Foo")
        #expect(app.version == "2.5")
        #expect(app.executable == "FooExec")
        #expect(app.identity.target != nil)
        #expect(app.officialUninstaller == nil)
    }

    @Test func excludesProtectedBundleIDsButAllowsAppleUninstallable() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "FakeMail", bundleID: "com.apple.mail")        // system-critical
        try writeApp(at: appsDir, name: "FakeFinder", bundleID: "com.apple.finder")    // system-critical
        try writeApp(at: appsDir, name: "FakeGarageBand", bundleID: "com.apple.garageband") // uninstallable
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.example.Foo")

        let apps = AppInventory(roots: [appsDir])
            .scan(protection: ProtectionPolicy(home: home, ownLogDirectory: ""))
        #expect(apps.map(\.bundleID).sorted() == ["com.apple.garageband", "com.example.Foo"])
    }

    @Test func officialUninstallerVendors() {
        let p = ProtectionPolicy(home: "/Users/u", ownLogDirectory: "")
        #expect(p.officialUninstallerVendor(bundleID: "com.eset.esets", name: "ESET") == "ESET")
        #expect(p.officialUninstallerVendor(bundleID: "com.example.Foo", name: "Foo") == nil)
    }
}

@Suite struct UninstallEngineTests {
    @Test func planCapturesIdentitiesAndSizes() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.example.Foo", executable: "FooExec")
        try mkdir(home + "/Library/Caches/com.example.Foo")
        try touch(home + "/Library/Preferences/com.example.Foo.plist")

        let engine = UninstallEngine(home: home, deleter: makeDeleter(home: home))
        let app = InstalledApp(path: appsDir + "/Foo.app", name: "Foo",
                               bundleID: "com.example.Foo", version: nil, executable: "FooExec",
                               size: .zero, lastUsed: nil,
                               identity: PathIdentity.capture(appsDir + "/Foo.app"),
                               officialUninstaller: nil)
        let plan = engine.plan(for: app, siblings: [], probes: idleProbes)

        #expect(plan.bundleItem.path == app.path)
        #expect(plan.skipped.isEmpty)
        #expect(plan.leftovers.map(\.path).sorted() == [
            home + "/Library/Caches/com.example.Foo",
            home + "/Library/Preferences/com.example.Foo.plist",
        ])
        for item in plan.leftovers { #expect(item.identity.target != nil) }
    }

    @Test func executeRefusesRunningApp() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.example.Foo", executable: "FooExec")

        let engine = UninstallEngine(home: home, deleter: makeDeleter(home: home))
        let app = InstalledApp(path: appsDir + "/Foo.app", name: "Foo",
                               bundleID: "com.example.Foo", version: nil, executable: "FooExec",
                               size: .zero, lastUsed: nil,
                               identity: PathIdentity.capture(appsDir + "/Foo.app"),
                               officialUninstaller: nil)
        let running = ProbeContext(
            processes: ProcessSnapshot(entries: [], bundleIDs: ["com.example.foo"], complete: true),
            openFiles: OpenFilesSnapshot(paths: [], complete: true))
        #expect(throws: UninstallError.appRunning("Foo")) {
            _ = try engine.execute(app: app, items: [], probes: running)
        }
        let incomplete = ProbeContext(
            processes: ProcessSnapshot(entries: [], bundleIDs: [], complete: false),
            openFiles: OpenFilesSnapshot(paths: [], complete: true))
        #expect(throws: UninstallError.processStateUnknown) {
            _ = try engine.execute(app: app, items: [], probes: incomplete)
        }
    }

    @Test func processInsideBundleCountsAsRunning() throws {
        // U2: a process whose executable lives inside the .app must block the uninstall
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.example.Foo", executable: "FooExec")

        let engine = UninstallEngine(home: home, deleter: makeDeleter(home: home))
        let appPath = appsDir + "/Foo.app"
        let app = InstalledApp(path: appPath, name: "Foo",
                               bundleID: "com.example.Foo", version: nil, executable: "FooExec",
                               size: .zero, lastUsed: nil,
                               identity: PathIdentity.capture(appPath),
                               officialUninstaller: nil)
        let helperRunning = ProbeContext(
            processes: ProcessSnapshot(entries: [
                ProcessSnapshot.Entry(pid: 42, name: "helperd",
                                      path: appPath + "/Contents/Library/helperd",
                                      arguments: ""),
            ], bundleIDs: [], complete: true),
            openFiles: OpenFilesSnapshot(paths: [], complete: true))
        #expect(throws: UninstallError.appRunning("Foo")) {
            _ = try engine.execute(app: app, items: [], probes: helperRunning)
        }
    }

    @Test func darwinUserCacheIsUserDomain() throws {
        // U3: /var/folders/.../C/<bundle id> belongs to the user, not the admin-only list
        guard let cacheDir = DarwinDirs.userCacheDir() else { return }
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.macclean.testFoo", executable: "FooExec")
        let fixture = cacheDir + "com.macclean.testFoo"
        try mkdir(fixture)
        defer { try? FileManager.default.removeItem(atPath: fixture) }

        let engine = UninstallEngine(home: home, deleter: makeDeleter(home: home))
        let appPath = appsDir + "/Foo.app"
        let app = InstalledApp(path: appPath, name: "Foo",
                               bundleID: "com.macclean.testFoo", version: nil, executable: "FooExec",
                               size: .zero, lastUsed: nil,
                               identity: PathIdentity.capture(appPath),
                               officialUninstaller: nil)
        let plan = engine.plan(for: app, siblings: [], probes: idleProbes)
        let item = plan.leftovers.first { $0.path == fixture }
        #expect(item != nil)
        #expect(item?.requiresAdmin == false)
    }

    @Test func danglingSymlinkSurvivesDedupe() throws {
        // U4: stat() fails on a dangling link; lstat() identity must be used instead
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lib = home + "/Library"
        try mkdir(lib + "/Caches")
        try FileManager.default.createSymbolicLink(
            atPath: lib + "/Caches/com.example.Foo", withDestinationPath: lib + "/gone")
        try touch(lib + "/Preferences/com.example.Foo.plist")

        let engine = UninstallEngine(home: home, deleter: makeDeleter(home: home))
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.example.Foo", executable: "FooExec")
        let appPath = appsDir + "/Foo.app"
        let app = InstalledApp(path: appPath, name: "Foo",
                               bundleID: "com.example.Foo", version: nil, executable: "FooExec",
                               size: .zero, lastUsed: nil,
                               identity: PathIdentity.capture(appPath),
                               officialUninstaller: nil)
        let plan = engine.plan(for: app, siblings: [], probes: idleProbes)
        let paths = plan.leftovers.map(\.path)
        #expect(paths.contains(lib + "/Caches/com.example.Foo"))
        #expect(paths.contains(lib + "/Preferences/com.example.Foo.plist"))
    }

    @Test func symlinkAndTargetBothSurviveDedupe() throws {
        // U4: a link and its target are different objects; dedupe must not collapse them
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lib = home + "/Library"
        try mkdir(lib + "/Logs/com.example.Foo")
        try mkdir(lib + "/Caches")
        try FileManager.default.createSymbolicLink(
            atPath: lib + "/Caches/com.example.Foo",
            withDestinationPath: lib + "/Logs/com.example.Foo")

        let engine = UninstallEngine(home: home, deleter: makeDeleter(home: home))
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.example.Foo", executable: "FooExec")
        let appPath = appsDir + "/Foo.app"
        let app = InstalledApp(path: appPath, name: "Foo",
                               bundleID: "com.example.Foo", version: nil, executable: "FooExec",
                               size: .zero, lastUsed: nil,
                               identity: PathIdentity.capture(appPath),
                               officialUninstaller: nil)
        let plan = engine.plan(for: app, siblings: [], probes: idleProbes)
        let paths = plan.leftovers.map(\.path)
        #expect(paths.contains(lib + "/Caches/com.example.Foo"))
        #expect(paths.contains(lib + "/Logs/com.example.Foo"))
    }

    @Test func executeRefusesOfficialUninstallerApps() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let engine = UninstallEngine(home: home, deleter: makeDeleter(home: home))
        let app = InstalledApp(path: home + "/ESET.app", name: "ESET",
                               bundleID: "com.eset.esets", version: nil, executable: nil,
                               size: .zero, lastUsed: nil,
                               identity: PathIdentity.capture(home + "/ESET.app"),
                               officialUninstaller: "ESET")
        #expect(throws: UninstallError.officialUninstallerRequired("ESET")) {
            _ = try engine.execute(app: app, items: [], probes: idleProbes)
        }
    }

    @Test func executeTrashesBundleAndSelectedLeftovers() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let appsDir = home + "/Applications"
        try writeApp(at: appsDir, name: "Foo", bundleID: "com.example.Foo", executable: "FooExec")
        let cache = home + "/Library/Caches/com.example.Foo"
        let plist = home + "/Library/Preferences/com.example.Foo.plist"
        try mkdir(cache)
        try touch(plist)

        let engine = UninstallEngine(home: home, deleter: makeDeleter(home: home))
        let app = InstalledApp(path: appsDir + "/Foo.app", name: "Foo",
                               bundleID: "com.example.Foo", version: nil, executable: "FooExec",
                               size: .zero, lastUsed: nil,
                               identity: PathIdentity.capture(appsDir + "/Foo.app"),
                               officialUninstaller: nil)
        let plan = engine.plan(for: app, siblings: [], probes: idleProbes)
        // user unchecks the plist: only bundle + cache are trashed
        let items = ([plan.bundleItem] + plan.leftovers).filter { $0.path != plist }
        let result = try engine.execute(app: app, items: items, probes: idleProbes)

        #expect(result.removedCount == 2)
        #expect(!FileStat.exists(app.path))
        #expect(!FileStat.exists(cache))
        #expect(FileStat.exists(plist))
    }

    @Test func siblingsDetectedByNameAndBundleID() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        func app(_ name: String, _ id: String, _ dir: String) -> InstalledApp {
            InstalledApp(path: dir + "/" + name + ".app", name: name, bundleID: id,
                         version: nil, executable: nil, size: .zero, lastUsed: nil,
                         identity: PathIdentity.capture(dir + "/" + name + ".app"),
                         officialUninstaller: nil)
        }
        let foo = app("Foo", "com.example.Foo", "/a")
        let fooBeta = app("Foo Beta", "com.example.Foobeta", "/a")   // same base name
        let sameID = app("FooHelper", "com.example.foo", "/b")       // same bundle id
        let other = app("Bar", "com.other.Bar", "/a")
        let siblings = UninstallEngine.siblings(of: foo, in: [foo, fooBeta, sameID, other])
        #expect(siblings.map(\.name).sorted() == ["Foo Beta", "FooHelper"])
    }
}
