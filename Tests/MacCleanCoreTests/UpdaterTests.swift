import Foundation
@testable import MacCleanCore
import Testing

@Suite struct UpdaterTests {
    @Test func semanticVersionParsingAndOrdering() {
        #expect(SemanticVersion(parsing: "v0.2.1") == SemanticVersion(0, 2, 1))
        #expect(SemanticVersion(parsing: "0.2.2") == SemanticVersion(0, 2, 2))
        #expect(SemanticVersion(parsing: "v1.0.0-beta.1") == SemanticVersion(1, 0, 0))
        #expect(SemanticVersion(parsing: "invalid") == nil)

        let v021 = SemanticVersion(0, 2, 1)
        let v022 = SemanticVersion(0, 2, 2)
        let v030 = SemanticVersion(0, 3, 0)
        let v100 = SemanticVersion(1, 0, 0)

        #expect(v021 < v022)
        #expect(v022 < v030)
        #expect(v030 < v100)
        #expect(!(v022 < v021))
    }

    @Test func parseGitHubReleasePayload() throws {
        let json = """
        {
          "tag_name": "v0.2.2",
          "name": "MacClean v0.2.2",
          "body": "### What's Changed\\n- Added automatic update",
          "html_url": "https://github.com/kwakchangkyoung/mc/releases/tag/v0.2.2",
          "assets": [
            {
              "name": "MacClean-v0.2.2-macos.zip",
              "browser_download_url": "https://github.com/kwakchangkyoung/mc/releases/download/v0.2.2/MacClean-v0.2.2-macos.zip",
              "size": 2588672
            },
            {
              "name": "MacClean-v0.2.2-macos.dmg",
              "browser_download_url": "https://github.com/kwakchangkyoung/mc/releases/download/v0.2.2/MacClean-v0.2.2-macos.dmg",
              "size": 3481600
            },
            {
              "name": "SHA256SUMS.txt",
              "browser_download_url": "https://github.com/kwakchangkyoung/mc/releases/download/v0.2.2/SHA256SUMS.txt",
              "size": 184
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try ReleaseUpdater.parseRelease(jsonData: json)
        #expect(release.tagName == "v0.2.2")
        #expect(release.version == SemanticVersion(0, 2, 2))
        #expect(release.title == "MacClean v0.2.2")
        #expect(release.zipAsset?.name == "MacClean-v0.2.2-macos.zip")
        #expect(release.dmgAsset?.name == "MacClean-v0.2.2-macos.dmg")
        #expect(release.checksumAsset?.name == "SHA256SUMS.txt")
    }

    @Test func parseExpectedSHA256FromChecksumFile() {
        let sumText = """
        37c2f340a3a9504fd50aabba6dc2ed19467fe5d37f30f04eebbb81700635da13  MacClean-v0.2.1-macos.zip
        67db4f29fb79148f711d78b0c2e6b2b6074f4f8361fb2d544b5b18561a704e0e  MacClean-v0.2.1-macos.dmg
        """
        #expect(
            ReleaseUpdater.expectedSHA256(for: "MacClean-v0.2.1-macos.zip", in: sumText)
                == "37c2f340a3a9504fd50aabba6dc2ed19467fe5d37f30f04eebbb81700635da13"
        )
        #expect(
            ReleaseUpdater.expectedSHA256(for: "MacClean-v0.2.1-macos.dmg", in: sumText)
                == "67db4f29fb79148f711d78b0c2e6b2b6074f4f8361fb2d544b5b18561a704e0e"
        )
        #expect(ReleaseUpdater.expectedSHA256(for: "other.zip", in: sumText) == nil)
    }
}
