import Foundation
import CryptoKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

final class AppUpdatePolicyTests: HistoryTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private func repository() throws -> UpdateRepository { try UpdateRepository(owner: "orkunisitmak", name: "clipboardline") }
    private func manifest(repository: String = "orkunisitmak/clipboardline", version: String = "1.5.0-review.27", build: Int = 35,
                          size: Int64 = 1024, hash: String = String(repeating: "a", count: 64), minimumOS: String = "14.0", schema: Int = 1,
                          archiveName: String? = nil) -> UpdateManifest {
        UpdateManifest(schemaVersion: schema, repository: repository, version: version, build: build, minimumSystemVersion: minimumOS,
                       archiveName: archiveName ?? "ClipboardLine-\(version)-build\(build).zip", archiveSize: size, archiveSHA256: hash)
    }
    private func envelope(_ value: UpdateManifest, signingKey: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        return try JSONEncoder().encode(SignedUpdateEnvelope(payload: payload.base64EncodedString(), signature: try (signingKey ?? key).signature(for: payload).base64EncodedString()))
    }
    private func verify(_ data: Data, currentBuild: Int = 34) throws -> UpdateManifest {
        try AppUpdatePolicy.verifyManifest(data: data, publicKey: key.publicKey.rawRepresentation, repository: repository(), currentBuild: currentBuild)
    }
    private func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }

    func testValidSignedManifestKeepsAuthenticatedBuildAndArchiveMetadata() throws {
        let expected = manifest()
        XCTAssertEqual(try verify(envelope(expected)), expected)
        XCTAssertEqual(try verify(envelope(manifest(build: 100)), currentBuild: 99).build, 100)
    }

    func testPayloadTamperingWrongKeyAndMalformedSignaturesAreRejected() throws {
        let valid = try envelope(manifest())
        let signed = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: valid)
        let altered = try JSONEncoder().encode(SignedUpdateEnvelope(payload: JSONEncoder().encode(manifest(build: 900)).base64EncodedString(), signature: signed.signature))
        XCTAssertTrue(rejects { _ = try verify(altered) })
        XCTAssertTrue(rejects { _ = try verify(envelope(manifest(), signingKey: Curve25519.Signing.PrivateKey())) })
        for signature in ["!", "", Data(repeating: 0, count: 64).base64EncodedString(), Data(repeating: 0, count: 63).base64EncodedString()] {
            let invalid = try JSONEncoder().encode(SignedUpdateEnvelope(payload: signed.payload, signature: signature))
            XCTAssertTrue(rejects { _ = try verify(invalid) })
        }
        XCTAssertTrue(rejects { _ = try AppUpdatePolicy.verifyManifest(data: valid, publicKey: Data(repeating: 0, count: 31), repository: repository(), currentBuild: 34) })
    }

    func testManifestMustBelongToRepositoryAndIncreaseBuild() throws {
        for invalid in [manifest(repository: "someone/clipboardline"), manifest(build: 34), manifest(build: 1), manifest(build: -1), manifest(schema: 2)] {
            XCTAssertTrue(rejects { _ = try verify(envelope(invalid)) })
        }
        XCTAssertTrue(rejects { _ = try verify(envelope(manifest()), currentBuild: -1) })
    }

    func testArchivePathSizeDigestAndMinimumSystemVersionAreValidatedAfterSignature() throws {
        let invalid = [manifest(version: "../escape"), manifest(version: "1.5/escape"), manifest(version: "1.5\n"), manifest(version: "1.5?token=secret"),
                       manifest(archiveName: "../ClipboardLine.zip"), manifest(archiveName: "other.zip"), manifest(size: 0), manifest(size: -1),
                       manifest(size: AppUpdatePolicy.maxArchiveSize + 1), manifest(hash: String(repeating: "a", count: 63)),
                       manifest(hash: String(repeating: "g", count: 64)), manifest(hash: String(repeating: "A", count: 64)),
                       manifest(minimumOS: "13.0"), manifest(minimumOS: "14..0"), manifest(minimumOS: "14.0garbage"), manifest(minimumOS: "14.0.0.1")]
        for item in invalid { XCTAssertTrue(rejects { _ = try verify(envelope(item)) }, "Accepted \(item)") }
        XCTAssertEqual(try verify(envelope(manifest(size: AppUpdatePolicy.maxArchiveSize))).archiveSize, AppUpdatePolicy.maxArchiveSize)
    }

    func testEnvelopeMustContainBoundedCanonicalBase64AndSignedJSON() throws {
        for bytes in [Data(), Data("{}".utf8), Data(repeating: 0x20, count: 65_537)] { XCTAssertTrue(rejects { _ = try verify(bytes) }) }
        for payload in ["!", "Zg", "Zg==\n", Data(repeating: 0, count: 16_385).base64EncodedString()] {
            let invalid = try JSONEncoder().encode(SignedUpdateEnvelope(payload: payload, signature: Data(repeating: 0, count: 64).base64EncodedString()))
            XCTAssertTrue(rejects { _ = try verify(invalid) })
        }
        let payload = Data("not JSON".utf8)
        let invalidJSON = try JSONEncoder().encode(SignedUpdateEnvelope(payload: payload.base64EncodedString(), signature: key.signature(for: payload).base64EncodedString()))
        XCTAssertTrue(rejects { _ = try verify(invalidJSON) })
    }

    func testReleaseDecodingAndFixedDownloadURLsRejectRedirectAndCredentialInjection() throws {
        let repo = try repository()
        let data = Data("""
        {"id": 10, "tag_name": "v1.5.0-review.27", "draft": false, "prerelease": true, "assets": [
        {"id": 9, "name": "update.json", "size": 100, "url": "https://api.github.com/repos/orkunisitmak/clipboardline/releases/assets/9", "browser_download_url": "https://github.com/orkunisitmak/clipboardline/releases/download/v1.5.0-review.27/update.json"}]}
        """.utf8)
        let release = try JSONDecoder().decode(GitHubUpdateRelease.self, from: data)
        XCTAssertEqual(release.tagName, "v1.5.0-review.27"); XCTAssertTrue(release.prerelease)
        let asset = try XCTUnwrap(release.assets.first)
        XCTAssertTrue(repo.acceptsAsset(asset, tag: release.tagName))
        XCTAssertNil(repo.releasesURL.query); XCTAssertNil(try repo.releaseAssetURL(id: 9).query)
        XCTAssertEqual(repo.releasesURL.absoluteString, "https://api.github.com/repos/orkunisitmak/clipboardline/releases")
        XCTAssertEqual(try repo.releaseURL(tag: release.tagName).absoluteString, "https://github.com/orkunisitmak/clipboardline/releases/tag/v1.5.0-review.27")
        for badURL in ["http://api.github.com/repos/orkunisitmak/clipboardline/releases/assets/9", "https://api.github.com/repos/someone/clipboardline/releases/assets/9", "https://api.github.com/repos/orkunisitmak/clipboardline/releases/assets/9?token=secret", "https://api.github.com.evil.test/repos/orkunisitmak/clipboardline/releases/assets/9", "https://secret@api.github.com/repos/orkunisitmak/clipboardline/releases/assets/9"] {
            let bad = GitHubUpdateAsset(id: 9, name: asset.name, size: asset.size, url: URL(string: badURL)!, browserDownloadURL: asset.browserDownloadURL)
            XCTAssertFalse(repo.acceptsAsset(bad, tag: release.tagName))
        }
        let wrongBrowser = GitHubUpdateAsset(id: 9, name: asset.name, size: asset.size, url: asset.url, browserDownloadURL: URL(string: "https://github.com/orkunisitmak/clipboardline/releases/download/vOther/update.json")!)
        XCTAssertFalse(repo.acceptsAsset(wrongBrowser, tag: release.tagName))
        for component in ["../escape", "name?token=secret", "name#fragment", "name/child", "name%2Fchild", ""] {
            XCTAssertTrue(rejects { _ = try UpdateRepository(owner: component, name: "clipboardline") })
            XCTAssertTrue(rejects { _ = try UpdateRepository(owner: "orkunisitmak", name: component) })
            XCTAssertTrue(rejects { _ = try repo.releaseURL(tag: component) })
        }
        XCTAssertTrue(rejects { _ = try repo.releaseAssetURL(id: 0) })
    }

    func testUpdateErrorMessagesAreTranslatedInEveryCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/Tendedero/Resources")
        let folders = try FileManager.default.contentsOfDirectory(atPath: resources.path).filter { $0.hasSuffix(".lproj") }
        XCTAssertGreaterThan(folders.count, 1)
        // Catalog keys are the English source strings; errorDescription itself may already be translated.
        let policy = ["The update repository is invalid.", "The release contains an invalid download address.", "The update manifest is malformed.",
                      "The update manifest signature is invalid.", "The update manifest contains invalid release information.",
                      "The update belongs to another repository.", "The update is not newer than the installed application.",
                      "The update archive exceeds the download limit."]
        let installer = ["The update has no application information.", "The update belongs to another application.", "The update executable is invalid.",
                         "The update staging directory is not private.", "The update is missing a supported architecture.", "The application signature is missing.",
                         "The application signature is invalid.", "The signing certificate could not be read.", "An ad-hoc or unrelated application cannot install updates.",
                         "The application identity is missing.", "The application identity could not be read.", "The application identity is empty.",
                         "The installed build is invalid.", "The downloaded version does not match the release.", "This update needs a newer version of macOS.",
                         "The update changed the trusted application identity.", "The update is not signed by the installed application's publisher.",
                         "The installed architectures have different signing identities.", "The update download is incomplete.", "The update download failed its integrity check.",
                         "The update staging directory is already in use.", "The update archive could not be opened.", "The installed application path is unsafe.",
                         "Move the app to a writable Applications folder before updating.", "The update installer is missing."]
        let messages = policy + installer
        for folder in folders {
            let table = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent(folder).appendingPathComponent("Localizable.strings")) as? [String: String])
            for message in messages { XCTAssertNotNil(table[message], "\(folder) has no entry for \(message)") }
        }
    }
}
