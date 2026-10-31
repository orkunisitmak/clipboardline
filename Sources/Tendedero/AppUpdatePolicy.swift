import Foundation
import CryptoKit

enum AppUpdatePolicyError: Error, LocalizedError {
    case invalidRepository, invalidRelease, invalidEnvelope, invalidSignature, invalidManifest
    case wrongRepository, nonIncreasingBuild, oversizedArchive

    var errorDescription: String? {
        switch self {
        case .invalidRepository: L("The update repository is invalid.")
        case .invalidRelease: L("The release contains an invalid download address.")
        case .invalidEnvelope: L("The update manifest is malformed.")
        case .invalidSignature: L("The update manifest signature is invalid.")
        case .invalidManifest: L("The update manifest contains invalid release information.")
        case .wrongRepository: L("The update belongs to another repository.")
        case .nonIncreasingBuild: L("The update is not newer than the installed application.")
        case .oversizedArchive: L("The update archive exceeds the download limit.")
        }
    }
}

/// Only GitHub's fixed API and repository paths are accepted. No release can
/// provide an arbitrary server URL, query credential or alternate repository.
struct UpdateRepository: Equatable {
    let owner: String
    let name: String

    init(owner: String, name: String) throws {
        guard owner.count <= 39, name.count <= 100,
              Self.matches(owner, "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"),
              Self.matches(name, "^[A-Za-z0-9_.-]+$"), name != ".", name != ".." else {
            throw AppUpdatePolicyError.invalidRepository
        }
        self.owner = owner; self.name = name
    }

    var slug: String { "\(owner)/\(name)" }
    var releasesURL: URL { URL(string: "https://api.github.com/repos/\(slug)/releases")! }

    func releaseAssetURL(id: Int) throws -> URL {
        guard id > 0 else { throw AppUpdatePolicyError.invalidRelease }
        return URL(string: "https://api.github.com/repos/\(slug)/releases/assets/\(id)")!
    }

    func releaseURL(tag: String) throws -> URL {
        guard Self.isSafeReleaseComponent(tag) else { throw AppUpdatePolicyError.invalidRelease }
        return URL(string: "https://github.com/\(slug)/releases/tag/")!.appendingPathComponent(tag)
    }

    func acceptsAsset(_ asset: GitHubUpdateAsset, tag: String) -> Bool {
        guard asset.size > 0, Self.isSafeReleaseComponent(tag), Self.isSafeReleaseComponent(asset.name),
              let expectedAPI = try? releaseAssetURL(id: asset.id),
              Self.isPlainHTTPS(asset.url, host: "api.github.com"), asset.url == expectedAPI,
              Self.isPlainHTTPS(asset.browserDownloadURL, host: "github.com") else { return false }
        let expectedDownload = URL(string: "https://github.com/\(slug)/releases/download/")!
            .appendingPathComponent(tag).appendingPathComponent(asset.name)
        return asset.browserDownloadURL == expectedDownload
    }

    private static func isPlainHTTPS(_ url: URL, host: String) -> Bool {
        url.scheme == "https" && url.host == host && url.port == nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
    }

    static func isSafeReleaseComponent(_ value: String) -> Bool {
        value.utf8.count <= 180 && matches(value, "^[A-Za-z0-9][A-Za-z0-9._+-]*$")
            && value != "." && value != ".."
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
}

struct GitHubUpdateRelease: Decodable {
    let id: Int
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubUpdateAsset]

    enum CodingKeys: String, CodingKey {
        case id, draft, prerelease, assets
        case tagName = "tag_name"
    }
}

struct GitHubUpdateAsset: Decodable {
    let id: Int
    let name: String
    let size: Int64
    let url: URL
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case id, name, size, url
        case browserDownloadURL = "browser_download_url"
    }
}

struct SignedUpdateEnvelope: Codable {
    let payload: String
    let signature: String
}

struct UpdateManifest: Codable, Equatable {
    let schemaVersion: Int
    let repository: String
    let version: String
    let build: Int
    let minimumSystemVersion: String
    let archiveName: String
    let archiveSize: Int64
    let archiveSHA256: String
}

enum AppUpdatePolicy {
    static let maxArchiveSize: Int64 = 1_073_741_824

    /// Authenticate the exact payload bytes before decoding or trusting any
    /// release fields. The code-signing identity is checked again on the app.
    static func verifyManifest(data: Data, publicKey: Data, repository: UpdateRepository, currentBuild: Int) throws -> UpdateManifest {
        guard data.count <= 65_536,
              let envelope = try? JSONDecoder().decode(SignedUpdateEnvelope.self, from: data),
              let payload = canonicalBase64(envelope.payload), payload.count <= 16_384,
              let signature = canonicalBase64(envelope.signature), signature.count == 64 else {
            throw AppUpdatePolicyError.invalidEnvelope
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else { throw AppUpdatePolicyError.invalidSignature }
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: payload) else {
            throw AppUpdatePolicyError.invalidManifest
        }
        guard manifest.repository == repository.slug else { throw AppUpdatePolicyError.wrongRepository }
        guard currentBuild >= 0, manifest.build > currentBuild else { throw AppUpdatePolicyError.nonIncreasingBuild }
        guard manifest.archiveSize <= maxArchiveSize else { throw AppUpdatePolicyError.oversizedArchive }
        let os = manifest.minimumSystemVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard manifest.schemaVersion == 1, manifest.archiveSize > 0,
              UpdateRepository.isSafeReleaseComponent(manifest.version),
              manifest.version.first?.isNumber == true,
              manifest.archiveName == "ClipboardLine-\(manifest.version)-build\(manifest.build).zip",
              manifest.archiveSHA256.utf8.count == 64,
              manifest.archiveSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (1...3).contains(os.count),
              os.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0) != nil }),
              let major = Int(os[0]), major >= 14 else { throw AppUpdatePolicyError.invalidManifest }
        return manifest
    }

    private static func canonicalBase64(_ value: String) -> Data? {
        guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else { return nil }
        return data
    }
}
