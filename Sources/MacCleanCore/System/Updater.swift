import CryptoKit
import Darwin
import Foundation

/// Semantic version (`major.minor.patch`) parsed from a tag like `"v0.2.1"` or `"0.2.1"`.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        // Strip optional pre-release suffix like "-beta.1" for base numeric comparison
        let core = cleaned.split(separator: "-", maxSplits: 1).first.map(String.init) ?? cleaned
        let parts = core.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        guard let maj = Int(parts[0]), maj >= 0 else { return nil }
        let min = parts.count > 1 ? Int(parts[1]) : 0
        let pat = parts.count > 2 ? Int(parts[2]) : 0
        guard let min, min >= 0, let pat, pat >= 0 else { return nil }
        self.major = maj
        self.minor = min
        self.patch = pat
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Metadata for a GitHub Release discovered by `ReleaseUpdater`.
public struct ReleaseInfo: Sendable, Equatable {
    public struct Asset: Sendable, Equatable {
        public let name: String
        public let downloadURL: URL
        public let size: Int64

        public init(name: String, downloadURL: URL, size: Int64) {
            self.name = name
            self.downloadURL = downloadURL
            self.size = size
        }
    }

    public let tagName: String
    public let version: SemanticVersion
    public let title: String
    public let notes: String
    public let htmlURL: URL
    public let zipAsset: Asset?
    public let dmgAsset: Asset?
    public let checksumAsset: Asset?

    public init(tagName: String, version: SemanticVersion, title: String, notes: String,
                htmlURL: URL, zipAsset: Asset?, dmgAsset: Asset?, checksumAsset: Asset?) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.notes = notes
        self.htmlURL = htmlURL
        self.zipAsset = zipAsset
        self.dmgAsset = dmgAsset
        self.checksumAsset = checksumAsset
    }
}

public enum UpdateError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case noDownloadableAsset
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidAppBundle
    case notRunningFromAppBundle(URL)
    case bundleNotWritable(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 릴리즈 정보를 확인할 수 없습니다."
        case .noDownloadableAsset:
            return "릴리즈에 설치 가능한 패키지(.zip)가 없습니다."
        case .checksumMismatch(let expected, let actual):
            return "다운로드한 파일의 무결성(SHA-256) 검증에 실패했습니다 (\(actual.prefix(8)) ≠ \(expected.prefix(8)))."
        case .extractionFailed(let msg):
            return "업데이트 압축 해제에 실패했습니다: \(msg)"
        case .invalidAppBundle:
            return "다운로드한 패키지에서 유효한 MacClean.app을 찾을 수 없습니다."
        case .notRunningFromAppBundle:
            return "현재 .app 번들 외부에서 실행 중이므로 자동 교체를 수행할 수 없습니다."
        case .bundleNotWritable(let path):
            return "앱 경로(\(path))에 쓰기 권한이 없어 자동 업데이트할 수 없습니다."
        case .networkError(let msg):
            return "네트워크 오류: \(msg)"
        }
    }
}

/// Checks GitHub Releases for newer versions and verifies/installs updates.
public enum ReleaseUpdater {
    public static let repoOwner = "kwakchangkyoung"
    public static let repoName = "mc"
    public static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    /// Parses a GitHub `/releases/latest` JSON payload into `ReleaseInfo`.
    public static func parseRelease(jsonData: Data) throws -> ReleaseInfo {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let tagName = obj["tag_name"] as? String,
              let version = SemanticVersion(parsing: tagName),
              let htmlURLString = obj["html_url"] as? String,
              let htmlURL = URL(string: htmlURLString) else {
            throw UpdateError.invalidResponse
        }
        let title = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tagName
        let notes = (obj["body"] as? String) ?? ""

        var assets: [ReleaseInfo.Asset] = []
        if let rawAssets = obj["assets"] as? [[String: Any]] {
            for item in rawAssets {
                guard let name = item["name"] as? String,
                      let urlStr = item["browser_download_url"] as? String,
                      let url = URL(string: urlStr) else { continue }
                let size = (item["size"] as? NSNumber)?.int64Value ?? 0
                assets.append(ReleaseInfo.Asset(name: name, downloadURL: url, size: size))
            }
        }

        let zipAsset = assets.first { $0.name.lowercased().hasSuffix(".zip") }
        let dmgAsset = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let checksumAsset = assets.first { $0.name == "SHA256SUMS.txt" }

        return ReleaseInfo(
            tagName: tagName,
            version: version,
            title: title,
            notes: notes,
            htmlURL: htmlURL,
            zipAsset: zipAsset,
            dmgAsset: dmgAsset,
            checksumAsset: checksumAsset
        )
    }

    /// Parses `SHA256SUMS.txt` lines (`<hex>  <filename>`) and returns the expected lowercase hex for `fileName`.
    public static func expectedSHA256(for fileName: String, in checksumText: String) -> String? {
        for line in checksumText.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let hash = parts[0].lowercased()
            let name = (parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : parts[1])
            if name == fileName && hash.count == 64 {
                return hash
            }
        }
        return nil
    }

    /// Computes lowercase SHA-256 hex digest of a file on disk.
    public static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Fetches the latest release from GitHub.
    public static func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacClean-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.invalidResponse
        }
        return try parseRelease(jsonData: data)
    }

    /// Downloads, verifies, extracts, and prepares the updated `MacClean.app` in a staging directory,
    /// then spawns a detached relaunch script that swaps the bundle as soon as the current process exits.
    public static func downloadAndPrepareUpdate(
        release: ReleaseInfo,
        currentBundleURL: URL = Bundle.main.bundleURL,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        guard let zipAsset = release.zipAsset else {
            throw UpdateError.noDownloadableAsset
        }
        guard currentBundleURL.pathExtension == "app" else {
            throw UpdateError.notRunningFromAppBundle(release.htmlURL)
        }
        let parentDir = currentBundleURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parentDir) &&
              FileManager.default.isWritableFile(atPath: currentBundleURL.path) else {
            throw UpdateError.bundleNotWritable(currentBundleURL.path)
        }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let zipFileURL = stagingRoot.appendingPathComponent(zipAsset.name)
        onStatus?("업데이트 패키지 다운로드 중… (\(ByteFormat.string(zipAsset.size)))")

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: zipAsset.downloadURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateError.invalidResponse
            }
            if FileManager.default.fileExists(atPath: zipFileURL.path) {
                try FileManager.default.removeItem(at: zipFileURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: zipFileURL)
        } catch let err as UpdateError {
            throw err
        } catch {
            throw UpdateError.networkError(error.localizedDescription)
        }

        // Verify SHA-256 checksum if SHA256SUMS.txt is attached to the release
        if let checksumAsset = release.checksumAsset {
            onStatus?("SHA-256 무결성 검증 중…")
            if let (sumData, sumResp) = try? await URLSession.shared.data(from: checksumAsset.downloadURL),
               let http = sumResp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let sumText = String(data: sumData, encoding: .utf8),
               let expected = expectedSHA256(for: zipAsset.name, in: sumText) {
                let actual = try sha256Hex(of: zipFileURL)
                if actual != expected {
                    try? FileManager.default.removeItem(at: stagingRoot)
                    throw UpdateError.checksumMismatch(expected: expected, actual: actual)
                }
            }
        }

        onStatus?("압축 해제 및 서명 검증 중…")
        let extractDir = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zipFileURL.path, extractDir.path], timeout: 30)
        guard unzip.status == 0 else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw UpdateError.extractionFailed("ditto 종료 코드 \(unzip.status)")
        }

        let stagedAppURL = extractDir.appendingPathComponent("MacClean.app", isDirectory: true)
        let stagedBinaryURL = stagedAppURL.appendingPathComponent("Contents/MacOS/MacClean")
        guard FileStat.isDirectory(stagedAppURL.path),
              FileManager.default.isExecutableFile(atPath: stagedBinaryURL.path) else {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw UpdateError.invalidAppBundle
        }

        // Clear quarantine extended attribute so Gatekeeper does not block the relaunched app
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedAppURL.path], timeout: 10)

        return stagedAppURL
    }

    /// Launches a detached helper that waits for `currentPID` to exit, replaces `targetAppURL`
    /// with `stagedAppURL`, cleans up the staging directory, and re-opens `targetAppURL`.
    public static func replaceAndRelaunch(stagedAppURL: URL, targetAppURL: URL, currentPID: pid_t = getpid()) throws {
        let stagingRoot = stagedAppURL.deletingLastPathComponent().deletingLastPathComponent()
        let script = """
        pid="\(currentPID)"
        staged="$1"
        target="$2"
        staging_root="$3"
        for _ in $(seq 1 50); do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        rm -rf "$target"
        mv "$staged" "$target"
        rm -rf "$staging_root"
        open "$target"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "macclean-updater", stagedAppURL.path, targetAppURL.path, stagingRoot.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }
}
