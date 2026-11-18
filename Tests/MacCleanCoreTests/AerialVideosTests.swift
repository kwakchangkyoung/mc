import Foundation
import Testing
@testable import MacCleanCore

private let idleProbes = ProbeContext(
    processes: ProcessSnapshot(entries: [], bundleIDs: [], complete: true),
    openFiles: OpenFilesSnapshot(paths: [], complete: true)
)

private func makeHome() throws -> String {
    let home = NSTemporaryDirectory() + "macclean-aerial-" + UUID().uuidString
    try FileManager.default.createDirectory(
        atPath: AerialVideos.videosDir(ofHome: home), withIntermediateDirectories: true)
    return home
}

private func writeIndex(_ home: String, _ sections: [String: Any]) throws {
    let dir = AerialVideos.root(ofHome: home) + "/Store"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
        fromPropertyList: sections, format: .binary, options: 0)
    try data.write(to: URL(fileURLWithPath: dir + "/Index.plist"))
}

private func aerialChoice(_ assetID: String, configuration: Data? = nil) throws -> [String: Any] {
    let config = try configuration ?? PropertyListSerialization.data(
        fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
    return ["Provider": AerialVideos.aerialProvider, "Files": [String](), "Configuration": config]
}

private func content(_ choices: [[String: Any]], shuffle: Bool = false) -> [String: Any] {
    // the real plist stores the literal string "$null" when shuffle is off
    ["Choices": choices, "Shuffle": shuffle ? ["Enabled": true] : "$null"]
}

private func section(desktop: [String: Any]? = nil, idle: [String: Any]? = nil,
                     linked: [String: Any]? = nil) -> [String: Any] {
    var s: [String: Any] = ["Type": linked != nil ? "linked" : "individual"]
    if let d = desktop { s["Desktop"] = ["Content": d] }
    if let i = idle { s["Idle"] = ["Content": i] }
    if let l = linked { s["Linked"] = ["Content": l] }
    return s
}

@discardableResult
private func video(_ home: String, _ assetID: String) throws -> String {
    let path = AerialVideos.videosDir(ofHome: home) + "/\(assetID).mov"
    try Data(count: 1_024).write(to: URL(fileURLWithPath: path))
    return path
}

private func engine(home: String) -> CleanEngine {
    let protection = ProtectionPolicy(home: home, ownLogDirectory: home + "/Library/Logs/MacClean")
    return CleanEngine(home: home,
        deleter: SafeDeleter(policy: PathPolicy(home: home, protection: protection),
                             whitelist: Whitelist(expandedPatterns: []), log: nil))
}

private func aerialGroup(_ home: String) -> CleanGroup? {
    engine(home: home).scan().groups.first { $0.rule.allowance == .aerialVideos }
}

@Suite struct AerialVideosTests {
    let used = "F439B0A7-D18C-4B14-9681-6520E6A74FE9"

    @Test func inUseVideoExcludedOthersOffered() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let a = try video(home, used)
        let b = try video(home, "AAAAAAAA-1111-2222-3333-444444444444")
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(
                desktop: content([aerialChoice(used)]),
                idle: content([["Provider": "default", "Files": [String](), "Configuration": Data()]])),
        ])
        let group = try #require(aerialGroup(home))
        #expect(group.items.map(\.path) == [b])
        #expect(group.skipped.contains { $0.path == a && $0.reason == .inUse })
        #expect(group.inUseAssets == [used])
        #expect(group.note?.contains("휴지통을 비워야") == true)
    }

    @Test func desktopAndIdleAerialsBothExcluded() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let other = "BBBBBBBB-1111-2222-3333-444444444444"
        let a = try video(home, used)
        let b = try video(home, other)
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(
                desktop: content([aerialChoice(used)]),
                idle: content([aerialChoice(other)])),
        ])
        let group = try #require(aerialGroup(home))
        #expect(group.items.isEmpty)
        #expect(Set(group.skipped.map(\.path)) == [a, b])
        #expect(Set(group.inUseAssets) == [used, other])
    }

    @Test func perDisplayAndSpaceChoicesExcluded() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let onDisplay = "CCCCCCCC-1111-2222-3333-444444444444"
        let onSpace = "DDDDDDDD-1111-2222-3333-444444444444"
        let a = try video(home, onDisplay)
        let b = try video(home, onSpace)
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(desktop: content([aerialChoice(used)])),
            "Displays": ["disp-1": section(desktop: content([aerialChoice(onDisplay)]))],
            "Spaces": ["space-1": section(idle: content([aerialChoice(onSpace)]))],
        ])
        let group = try #require(aerialGroup(home))
        #expect(group.items.isEmpty)
        #expect(Set(group.skipped.map(\.path)) == [a, b])
        #expect(Set(group.inUseAssets) == [used, onDisplay, onSpace])
    }

    @Test func shuffleDetected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try video(home, used)
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(desktop: content([aerialChoice(used)], shuffle: true)),
        ])
        let group = try #require(aerialGroup(home))
        #expect(group.note?.contains("순환") == true)
    }

    @Test func nonAerialChoiceOffersEverything() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let a = try video(home, used)
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(
                desktop: content([["Provider": "default", "Files": [String](), "Configuration": Data()]])),
        ])
        let group = try #require(aerialGroup(home))
        #expect(group.items.map(\.path) == [a])
        #expect(group.skipped.isEmpty)
    }

    @Test func corruptPlistFailsClosed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try video(home, used)
        let dir = AerialVideos.root(ofHome: home) + "/Store"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "not a plist".write(toFile: dir + "/Index.plist", atomically: true, encoding: .utf8)
        let group = try #require(aerialGroup(home))
        #expect(group.items.isEmpty)
        #expect(group.note?.contains("사용할 수 없습니다") == true)
    }

    @Test func undecodableAerialChoiceFailsClosed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try video(home, used)
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(
                desktop: content([aerialChoice(used, configuration: Data([0x01, 0x02]))])),
        ])
        let group = try #require(aerialGroup(home))
        #expect(group.items.isEmpty)
        #expect(group.note?.contains("사용할 수 없습니다") == true)
    }

    @Test func linkedSectionTypeSupported() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let a = try video(home, used)
        let b = try video(home, "99999999-1111-2222-3333-444444444444")
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(linked: content([aerialChoice(used)])),
            "Displays": [String: Any](),
            "Spaces": [String: Any](),
            "SystemDefault": section(linked: content([aerialChoice(used)])),
        ])
        let group = try #require(aerialGroup(home))
        #expect(group.items.map(\.path) == [b])
        #expect(group.skipped.contains { $0.path == a && $0.reason == .inUse })
        #expect(group.inUseAssets == [used])
        #expect(group.note?.contains("사용할 수 없습니다") != true)
    }

    @Test func missingPlistFailsClosed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try video(home, used)
        let group = try #require(aerialGroup(home))
        #expect(group.items.isEmpty)
        #expect(group.note?.contains("사용할 수 없습니다") == true)
    }
}

@Suite struct AerialVideosProtectionTests {
    private func deleter(home: String) -> SafeDeleter {
        let protection = ProtectionPolicy(home: home, ownLogDirectory: home + "/Library/Logs/MacClean")
        return SafeDeleter(policy: PathPolicy(home: home, protection: protection),
                           whitelist: Whitelist(expandedPatterns: []), log: nil)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @Test func onlyVideosMovPassesTheAllowance() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = AerialVideos.root(ofHome: home)
        let mov = try video(home, "EEEEEEEE-1111-2222-3333-444444444444")
        let rest = [
            root + "/aerials/manifest/entries.json",
            root + "/aerials/thumbnails/AAAA.png",
            root + "/Store/Index.plist",
            root + "/aerials/videos",                       // the dir itself
            root + "/aerials/videos/subdir/file.mov",        // nested
            root + "/aerials/videos/movie.mp4",              // wrong extension
        ]
        for p in rest {
            try FileManager.default.createDirectory(
                atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if !p.hasSuffix("videos") { try Data().write(to: URL(fileURLWithPath: p)) }
        }
        let d = deleter(home: home)
        // without the rule allowance even a videos/*.mov stays protected
        #expect(d.check(mov, probes: idleProbes) != nil)
        #expect(d.check(mov, probes: idleProbes, allowance: .aerialVideos) == nil)
        for p in rest {
            #expect(d.check(p, probes: idleProbes, allowance: .aerialVideos) != nil,
                    "\(p) must stay refused")
        }
    }

    @Test func symlinkAndDirNamedMovStayRefused() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let target = try video(home, "FFFFFFFF-1111-2222-3333-444444444444")
        let dir = AerialVideos.videosDir(ofHome: home)
        try FileManager.default.createSymbolicLink(
            atPath: dir + "/link.mov", withDestinationPath: target)
        try FileManager.default.createDirectory(
            atPath: dir + "/fake.mov", withIntermediateDirectories: true)
        let d = deleter(home: home)
        #expect(d.check(dir + "/link.mov", probes: idleProbes, allowance: .aerialVideos) != nil)
        #expect(d.check(dir + "/fake.mov", probes: idleProbes, allowance: .aerialVideos) != nil)
        // and the scan never lists them either
        var scan = AerialVideos.Scan()
        AerialVideos.listVideos(home: home, inUse: [], into: &scan)
        #expect(scan.cleanable == [target])
    }

    @Test func symlinkedVideosDirFallsBackToProtected() throws {
        // aerials/videos -> a protected dir: the logical path looks like a video,
        // but the physical file is outside the real videos dir and must be refused
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = AerialVideos.root(ofHome: home)
        let store = root + "/Store"
        try mkdir(store)
        try Data(count: 8).write(to: URL(fileURLWithPath: store + "/x.mov"))
        let videos = AerialVideos.videosDir(ofHome: home)
        try FileManager.default.removeItem(atPath: videos)  // replace the real dir
        try FileManager.default.createSymbolicLink(atPath: videos, withDestinationPath: store)
        let d = deleter(home: home)
        #expect(d.check(videos + "/x.mov", probes: idleProbes, allowance: .aerialVideos) != nil)
    }

    @Test func symlinkedAerialsAncestorStaysRefused() throws {
        // an intermediate ancestor (aerials itself) symlinked elsewhere -> refused
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = AerialVideos.root(ofHome: home)
        let elsewhere = home + "/Library/Application Support/Elsewhere"
        try mkdir(elsewhere + "/videos")
        try Data(count: 8).write(to: URL(fileURLWithPath: elsewhere + "/videos/x.mov"))
        try FileManager.default.removeItem(atPath: AerialVideos.videosDir(ofHome: home))
        try FileManager.default.removeItem(atPath: root + "/aerials")
        try FileManager.default.createSymbolicLink(atPath: root + "/aerials",
                                                   withDestinationPath: elsewhere)
        let d = deleter(home: home)
        let logical = AerialVideos.videosDir(ofHome: home) + "/x.mov"
        #expect(d.check(logical, probes: idleProbes, allowance: .aerialVideos) != nil)
    }

    @Test func symlinkedHomeStillAllowed() throws {
        // $HOME itself may sit behind a symlink (e.g. /var -> /private/var):
        // physical == realPath(home) + videos/<name>.mov stays allowed
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let mov = try video(home, "AAAAAAAA-9999-8888-7777-666666666666")
        #expect(deleter(home: home).check(mov, probes: idleProbes,
                                         allowance: .aerialVideos) == nil)
    }

    @Test func analyzeTrashWithoutAllowanceRefusesVideo() throws {
        // the Analyze/uninstall path passes no allowance: a real video stays refused
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let mov = try video(home, "BBBBBBBB-9999-8888-7777-666666666666")
        let outcome = deleter(home: home).trash(mov, expected: nil, probes: idleProbes)
        guard case .skipped = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(FileStat.exists(mov))
    }
}

@Suite struct AerialVideosExecuteTests {
    @Test func executeMovesToTrash() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let victim = try video(home, "ABCDEF12-1111-2222-3333-444444444444")
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(
                desktop: content([["Provider": "default", "Files": [String](), "Configuration": Data()]])),
        ])
        let group = try #require(aerialGroup(home))
        #expect(group.items.map(\.path) == [victim])
        let result = engine(home: home).execute(group.items)
        #expect(result.removedCount == 1)
        #expect(result.failed.isEmpty)
        #expect(!FileStat.exists(victim))      // gone — via Trash, not removefile
        let trash = NSHomeDirectory() + "/.Trash/" + (victim as NSString).lastPathComponent
        #expect(FileStat.exists(trash))        // landed in the real Trash
        try? FileManager.default.removeItem(atPath: trash)
    }

    @Test func executeSkipsVideoThatBecameInUse() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = try video(home, "ABCDEF34-1111-2222-3333-444444444444")
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(
                desktop: content([["Provider": "default", "Files": [String](), "Configuration": Data()]])),
        ])
        let group = try #require(aerialGroup(home))
        // the wallpaper changed after the scan: the video is now in use
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(
                desktop: content([aerialChoice("ABCDEF34-1111-2222-3333-444444444444")])),
        ])
        let result = engine(home: home).execute(group.items)
        #expect(result.removedCount == 0)
        #expect(result.skipped.contains { $0.path == path })
        #expect(FileStat.exists(path))
    }

    @Test func executeFailsClosedWhenConfigUnreadable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = try video(home, "ABCDEF56-1111-2222-3333-444444444444")
        try writeIndex(home, [
            "AllSpacesAndDisplays": section(
                desktop: content([["Provider": "default", "Files": [String](), "Configuration": Data()]])),
        ])
        let group = try #require(aerialGroup(home))
        try FileManager.default.removeItem(
            atPath: AerialVideos.root(ofHome: home) + "/Store/Index.plist")
        let result = engine(home: home).execute(group.items)
        #expect(result.removedCount == 0)
        #expect(FileStat.exists(path))
    }
}
