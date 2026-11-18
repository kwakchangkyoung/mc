import Foundation

/// Downloaded macOS aerial wallpaper / screen-saver videos live in
/// `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<assetID>.mov`
/// (same `<assetID>` naming the thumbnails use). Which assets are in use is decided
/// by `Store/Index.plist` — every Desktop/Idle choice in every section
/// (AllSpacesAndDisplays, SystemDefault, and per-display/per-space entries under
/// Displays/Spaces). Idle choices with Provider "default" follow Desktop, so a plain
/// union of every aerial assetID is the safe in-use set.
///
/// FAILS CLOSED: an unreadable or unrecognised plist, or an aerial choice without a
/// decodable assetID, means "we cannot know what is in use" — offer nothing.
public enum AerialVideos {
    public static let aerialProvider = "com.apple.wallpaper.choice.aerials"

    public struct Scan: Sendable {
        /// assetIDs any configured wallpaper/screen saver refers to.
        public var inUseAssetIDs: Set<String> = []
        /// true when any aerial choice has Shuffle enabled (deleted files may re-download).
        public var shuffleOn = false
        /// Set when the config could not be trusted — offer nothing.
        public var unavailableReason: String?
        /// Regular `.mov` files under aerials/videos not referenced by any choice.
        public var cleanable: [String] = []
        /// In-use videos still on disk.
        public var inUseFiles: [String] = []
    }

    public static func root(ofHome home: String) -> String {
        home + "/Library/Application Support/com.apple.wallpaper"
    }
    public static func videosDir(ofHome home: String) -> String {
        root(ofHome: home) + "/aerials/videos"
    }

    public static func scan(home: String) -> Scan {
        var scan = Scan()
        guard let inUse = inUseAssets(home: home, shuffleOn: &scan.shuffleOn) else {
            scan.unavailableReason = "배경화면 설정(Index.plist)을 읽거나 해석할 수 없습니다"
            return scan
        }
        scan.inUseAssetIDs = inUse
        listVideos(home: home, inUse: inUse, into: &scan)
        return scan
    }

    /// nil = fail closed. Returns the union of every aerial assetID and sets shuffleOn.
    static func inUseAssets(home: String, shuffleOn: inout Bool) -> Set<String>? {
        let store = root(ofHome: home) + "/Store/Index.plist"
        guard let data = FileManager.default.contents(atPath: store),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                  as? [String: Any] else {
            return nil
        }
        var inUse = Set<String>()
        var entries = 0
        for (_, sectionValue) in root {
            guard let section = sectionValue as? [String: Any] else { return nil }
            // a section either holds Desktop/Idle itself (AllSpacesAndDisplays,
            // SystemDefault) or one level deeper (per-display Spaces/Displays entries)
            let holders = (section["Desktop"] != nil || section["Idle"] != nil)
                ? [section] : Array(section.values)
            for holder in holders {
                guard let holder = holder as? [String: Any] else { return nil }
                for key in ["Desktop", "Idle"] {
                    guard let entry = holder[key] else { continue }
                    entries += 1
                    guard let entry = entry as? [String: Any],
                          applyContent(entry["Content"], inUse: &inUse, shuffleOn: &shuffleOn)
                    else { return nil }
                }
            }
        }
        return entries > 0 ? inUse : nil
    }

    /// false = fail closed (unknown shape or undecodable aerial assetID).
    private static func applyContent(_ content: Any?, inUse: inout Set<String>,
                                     shuffleOn: inout Bool) -> Bool {
        guard let content = content as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else { return false }
        var hasAerial = false
        for choice in choices {
            guard let provider = choice["Provider"] as? String else { return false }
            if provider == aerialProvider {
                hasAerial = true
                guard let config = choice["Configuration"] as? Data,
                      let inner = (try? PropertyListSerialization
                          .propertyList(from: config, format: nil)) as? [String: Any],
                      let id = inner["assetID"] as? String, !id.isEmpty else { return false }
                inUse.insert(id)
            }
        }
        // Shuffle off is stored as the literal string "$null"; any other value means on
        if hasAerial, let sh = content["Shuffle"], (sh as? String) != "$null" { shuffleOn = true }
        return true
    }

    /// Only regular `.mov` files directly inside aerials/videos (no dirs, no symlinks)
    /// may ever be offered — the matching deletion allowance in PathPolicy checks the
    /// same predicate again at delete time.
    static func listVideos(home: String, inUse: Set<String>, into scan: inout Scan) {
        let dir = videosDir(ofHome: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names.sorted() where name.hasSuffix(".mov") {
            let path = dir + "/" + name
            guard !FileStat.isSymlink(path), !FileStat.isDirectory(path) else { continue }
            let assetID = (name as NSString).deletingPathExtension
            if inUse.contains(assetID) {
                scan.inUseFiles.append(path)
            } else {
                scan.cleanable.append(path)
            }
        }
    }
}
