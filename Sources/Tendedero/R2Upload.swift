import AppKit
import Combine
import CryptoKit
import Foundation
import Security

struct R2Configuration: Equatable, Sendable {
    var accountId: String = ""
    var accessKeyId: String = ""
    var bucket: String = ""
    var publicBaseUrl: String = ""
    var keyPrefix: String = ""

    var hasRequiredFields: Bool {
        !accountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !publicBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ValidatedR2Configuration: Equatable, Sendable {
    let endpoint: URL
    let accessKeyId: String
    let bucket: String
    let publicBaseUrl: String
    let keyPrefix: String
    let region: String
}

enum R2ValidationError: Error, LocalizedError, Equatable {
    case notConfigured
    case insecureEndpoint
    case invalidEndpoint
    case invalidBucket
    case missingAccessKeyId
    case missingSecretAccessKey
    case invalidPublicBaseUrl
    case invalidKeyPrefix
    case fileTooLarge
    case keychainFailure
    case httpStatus(Int, testing: Bool)
    case transportFailure

    var errorDescription: String? {
        switch self {
        case .notConfigured: L("Configure Cloudflare R2 in Settings first")
        case .insecureEndpoint: L("Cloudflare R2 endpoint must use HTTPS")
        case .invalidEndpoint: L("Enter a valid Cloudflare R2 Account ID or HTTPS endpoint")
        case .invalidBucket: L("Enter a valid R2 bucket name")
        case .missingAccessKeyId: L("Enter an R2 Access Key ID")
        case .missingSecretAccessKey: L("Enter an R2 Secret Access Key")
        case .invalidPublicBaseUrl: L("Enter a valid HTTPS public base URL (for example, your r2.dev or custom domain)")
        case .invalidKeyPrefix: L("Enter a valid key prefix without '..'")
        case .fileTooLarge: L("File is too large to upload (512 MB limit)")
        case .keychainFailure: L("Secret Access Key could not be saved in Keychain")
        case let .httpStatus(code, testing):
            String(format: testing ? L("Cloudflare R2 rejected the credentials or bucket (%d)") : L("Cloudflare R2 upload failed (%d)"), code)
        case .transportFailure: L("Cloudflare R2 connection failed")
        }
    }
}

enum R2Preferences {
    static let accountIdKey = "r2AccountId"
    static let accessKeyIdKey = "r2AccessKeyId"
    static let bucketKey = "r2Bucket"
    static let publicBaseUrlKey = "r2PublicBaseUrl"
    static let keyPrefixKey = "r2KeyPrefix"

    /// Reading preferences never mutates UserDefaults.
    static func load(from defaults: UserDefaults) -> R2Configuration {
        R2Configuration(
            accountId: defaults.string(forKey: accountIdKey) ?? "",
            accessKeyId: defaults.string(forKey: accessKeyIdKey) ?? "",
            bucket: defaults.string(forKey: bucketKey) ?? "",
            publicBaseUrl: defaults.string(forKey: publicBaseUrlKey) ?? "",
            keyPrefix: defaults.string(forKey: keyPrefixKey) ?? ""
        )
    }

    static func save(_ config: R2Configuration, to defaults: UserDefaults) {
        let pairs: [(String, String)] = [
            (accountIdKey, config.accountId.trimmingCharacters(in: .whitespacesAndNewlines)),
            (accessKeyIdKey, config.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)),
            (bucketKey, config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)),
            (publicBaseUrlKey, config.publicBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
            (keyPrefixKey, config.keyPrefix.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        for (key, value) in pairs {
            if value.isEmpty { defaults.removeObject(forKey: key) }
            else { defaults.set(value, forKey: key) }
        }
    }
}

enum R2Validator {
    static let maximumUploadBytes = 512 * 1024 * 1024
    private static let blockedSuffixes = ["local", "localhost", "internal", "home", "arpa", "lan", "corp", "localdomain", "onion", "invalid"]

    static func validate(_ raw: R2Configuration) throws -> ValidatedR2Configuration {
        let accountOrEndpoint = raw.accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountOrEndpoint.isEmpty else { throw R2ValidationError.invalidEndpoint }
        let endpoint = try parseEndpoint(accountOrEndpoint)

        let accessKeyId = raw.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKeyId.isEmpty, accessKeyId.utf8.count <= 128,
              accessKeyId.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw R2ValidationError.missingAccessKeyId
        }

        let bucket = raw.bucket.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidBucket(bucket) else { throw R2ValidationError.invalidBucket }

        let publicBaseUrl = try parsePublicBaseUrl(raw.publicBaseUrl)
        let keyPrefix = try normalizePrefix(raw.keyPrefix)

        return ValidatedR2Configuration(
            endpoint: endpoint,
            accessKeyId: accessKeyId,
            bucket: bucket,
            publicBaseUrl: publicBaseUrl,
            keyPrefix: keyPrefix,
            region: "auto"
        )
    }

    private static func isPublicHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        guard !lower.isEmpty, lower.utf8.count <= 253, lower.contains("."), !lower.hasSuffix(".") else { return false }
        if let address = PublicLinkAddress(lower) { return address.isPublic }
        guard lower.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { return false }
        if blockedSuffixes.contains(where: { lower == $0 || lower.hasSuffix("." + $0) }) { return false }
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
            && labels.last?.contains(where: { $0.isLetter }) == true
    }

    private static func parseEndpoint(_ value: String) throws -> URL {
        if value.contains("://") {
            guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else {
                throw R2ValidationError.invalidEndpoint
            }
            guard scheme == "https" else { throw R2ValidationError.insecureEndpoint }
            guard components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.port == nil || components.port == 443,
                  let host = components.host?.lowercased(), isPublicHost(host),
                  components.path.isEmpty || components.path == "/" else {
                throw R2ValidationError.invalidEndpoint
            }
            components.scheme = "https"
            components.host = host
            components.port = nil
            components.path = ""
            guard let url = components.url else { throw R2ValidationError.invalidEndpoint }
            return url
        }
        let cleaned = value.lowercased()
        guard (3...96).contains(cleaned.utf8.count),
              cleaned.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              !cleaned.hasPrefix("-"), !cleaned.hasSuffix("-"), !cleaned.hasPrefix("."), !cleaned.hasSuffix("."),
              !cleaned.contains("..") else {
            throw R2ValidationError.invalidEndpoint
        }
        let host = cleaned.hasSuffix(".r2.cloudflarestorage.com") ? cleaned : "\(cleaned).r2.cloudflarestorage.com"
        guard isPublicHost(host), let url = URL(string: "https://\(host)") else {
            throw R2ValidationError.invalidEndpoint
        }
        return url
    }

    private static func isValidBucket(_ bucket: String) -> Bool {
        guard (3...63).contains(bucket.utf8.count),
              !bucket.contains(".."),
              bucket.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              let first = bucket.utf8.first, let last = bucket.utf8.last,
              ((97...122).contains(first) || (48...57).contains(first)),
              ((97...122).contains(last) || (48...57).contains(last)) else {
            return false
        }
        return PublicLinkAddress(bucket) == nil
    }

    static func parsePublicBaseUrl(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), isPublicHost(host) else {
            throw R2ValidationError.invalidPublicBaseUrl
        }
        let pathSegments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !pathSegments.contains(where: { $0 == "." || $0 == ".." }),
              components.path.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw R2ValidationError.invalidPublicBaseUrl
        }
        components.scheme = "https"
        components.host = host
        components.port = nil
        components.path = pathSegments.isEmpty ? "" : "/" + pathSegments.joined(separator: "/")
        guard let url = components.url else { throw R2ValidationError.invalidPublicBaseUrl }
        var string = url.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        return string
    }

    static func normalizePrefix(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.utf8.count <= 128, !trimmed.contains("\\"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw R2ValidationError.invalidKeyPrefix
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw R2ValidationError.invalidKeyPrefix
        }
        return parts.joined(separator: "/")
    }

    static func makeObjectKey(prefix: String, token: String, fileExtension: String) -> String {
        let ext = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let safeExt = ext.isEmpty ? "bin" : ext
        let name = "\(token).\(safeExt)"
        return prefix.isEmpty ? name : "\(prefix)/\(name)"
    }

    static func randomToken(length: Int = 16) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<max(8, length)).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    static func publicObjectURL(baseUrl: String, objectKey: String) throws -> URL {
        let encodedKey = objectKey.split(separator: "/", omittingEmptySubsequences: true)
            .map(R2SigV4.uriEncode)
            .joined(separator: "/")
        guard let url = URL(string: "\(baseUrl)/\(encodedKey)"), url.scheme == "https" else {
            throw R2ValidationError.invalidPublicBaseUrl
        }
        return url
    }
}

protocol R2SecretStore: Sendable {
    func hasSecret() -> Bool
    func readSecret() throws -> String?
    func saveSecret(_ secret: String) throws
    func clearSecret() throws
}

final class InMemoryR2SecretStore: R2SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(initial: String? = nil) { stored = initial }

    func hasSecret() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stored != nil && !(stored?.isEmpty ?? true)
    }

    func readSecret() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func saveSecret(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { throw R2ValidationError.missingSecretAccessKey }
        lock.lock(); stored = trimmed; lock.unlock()
    }

    func clearSecret() throws {
        lock.lock(); stored = nil; lock.unlock()
    }
}

final class KeychainR2SecretStore: R2SecretStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()
    private var cachedPresence: Bool?

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "local.clipboardline.app").r2",
         account: String = "secret-access-key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Queries item attributes only so checking status in UI never reads secret bytes.
    func hasSecret() -> Bool {
        lock.lock()
        if let cachedPresence { lock.unlock(); return cachedPresence }
        lock.unlock()
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        let present = status == errSecSuccess
        lock.lock(); cachedPresence = present; lock.unlock()
        return present
    }

    func readSecret() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            lock.lock(); cachedPresence = false; lock.unlock()
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw R2ValidationError.keychainFailure
        }
        lock.lock(); cachedPresence = true; lock.unlock()
        return value
    }

    func saveSecret(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
              trimmed.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw R2ValidationError.missingSecretAccessKey
        }
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            for (k, v) in attributes { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw R2ValidationError.keychainFailure }
        } else if updateStatus != errSecSuccess {
            throw R2ValidationError.keychainFailure
        }
        lock.lock(); cachedPresence = true; lock.unlock()
    }

    func clearSecret() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw R2ValidationError.keychainFailure
        }
        lock.lock(); cachedPresence = false; lock.unlock()
    }
}

enum R2SigV4 {
    struct SignedRequest: Equatable, Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let canonicalRequest: String
        let stringToSign: String
    }

    static func uriEncode<S: StringProtocol>(_ value: S) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            let unreserved = (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 45 || byte == 95 || byte == 46 || byte == 126
            if unreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(mac)
    }

    static func formatTimestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        let amz = String(format: "%@T%02d%02d%02dZ", stamp, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return (amz, stamp)
    }

    static func sign(
        method: String,
        endpoint: URL,
        pathSegments: [String],
        queryItems: [(String, String)] = [],
        extraHeaders: [String: String] = [:],
        payloadHash: String,
        accessKeyId: String,
        secretAccessKey: String,
        region: String = "auto",
        service: String = "s3",
        date: Date
    ) throws -> SignedRequest {
        guard let host = endpoint.host?.lowercased(), endpoint.scheme?.lowercased() == "https" else {
            throw R2ValidationError.invalidEndpoint
        }
        let encodedPath = "/" + pathSegments.map(uriEncode).joined(separator: "/")
        let encodedPairs: [(String, String)] = queryItems.map { (uriEncode($0.0), uriEncode($0.1)) }
        let sortedPairs = encodedPairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let encodedQuery = sortedPairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        var urlString = "https://\(host)\(encodedPath)"
        if !encodedQuery.isEmpty { urlString += "?\(encodedQuery)" }
        guard let url = URL(string: urlString) else { throw R2ValidationError.invalidEndpoint }

        let (amzDate, dateStamp) = formatTimestamps(date)
        var headers: [String: String] = [
            "host": host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate
        ]
        for (key, value) in extraHeaders {
            headers[key.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }

        let sortedKeys = headers.keys.sorted()
        let canonicalHeaders = sortedKeys.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = sortedKeys.joined(separator: ";")
        let canonicalRequest = [
            method.uppercased(),
            encodedPath,
            encodedQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let kDate = hmac(Data(("AWS4" + secretAccessKey).utf8), dateStamp)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        let kSigning = hmac(kService, "aws4_request")
        let signature = hmac(kSigning, stringToSign).map { String(format: "%02x", $0) }.joined()

        var wireHeaders = [String: String]()
        for key in sortedKeys where key != "host" {
            wireHeaders[key] = headers[key]
        }
        wireHeaders["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return SignedRequest(
            url: url,
            method: method.uppercased(),
            headers: wireHeaders,
            canonicalRequest: canonicalRequest,
            stringToSign: stringToSign
        )
    }
}

protocol R2HTTPTransport: Sendable {
    func send(url: URL, method: String, headers: [String: String], body: Data?) async throws -> (status: Int, body: Data)
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Signed S3 Authorization headers must never follow redirects.
        completionHandler(nil)
    }
}

final class URLSessionR2Transport: R2HTTPTransport, Sendable {
    private let session: URLSession
    private let delegate = NoRedirectSessionDelegate()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 180
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func send(url: URL, method: String, headers: [String: String], body: Data?) async throws -> (status: Int, body: Data) {
        guard url.scheme?.lowercased() == "https" else { throw R2ValidationError.insecureEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (responseData, response): (Data, URLResponse)
            if let body {
                (responseData, response) = try await session.upload(for: request, from: body)
            } else {
                (responseData, response) = try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw R2ValidationError.transportFailure }
            return (http.statusCode, responseData)
        } catch let error as CancellationError {
            throw error
        } catch let error as R2ValidationError {
            throw error
        } catch {
            throw R2ValidationError.transportFailure
        }
    }
}

enum R2Client {
    static func testConnection(
        configuration: ValidatedR2Configuration,
        secretAccessKey: String,
        transport: any R2HTTPTransport,
        now: Date = Date()
    ) async throws {
        let secret = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw R2ValidationError.missingSecretAccessKey }
        let emptyHash = R2SigV4.sha256Hex(Data())
        let signed = try R2SigV4.sign(
            method: "GET",
            endpoint: configuration.endpoint,
            pathSegments: [configuration.bucket],
            queryItems: [("list-type", "2"), ("max-keys", "1")],
            payloadHash: emptyHash,
            accessKeyId: configuration.accessKeyId,
            secretAccessKey: secret,
            region: configuration.region,
            date: now
        )
        let response = try await transport.send(url: signed.url, method: signed.method, headers: signed.headers, body: nil)
        guard response.status == 200 else {
            throw R2ValidationError.httpStatus(response.status, testing: true)
        }
    }

    static func uploadObject(
        data: Data,
        contentType: String,
        objectKey: String,
        configuration: ValidatedR2Configuration,
        secretAccessKey: String,
        transport: any R2HTTPTransport,
        now: Date = Date()
    ) async throws -> URL {
        let secret = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw R2ValidationError.missingSecretAccessKey }
        guard data.count <= R2Validator.maximumUploadBytes else { throw R2ValidationError.fileTooLarge }
        let keySegments = objectKey.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !keySegments.isEmpty else { throw R2ValidationError.invalidKeyPrefix }
        let payloadHash = R2SigV4.sha256Hex(data)
        let signed = try R2SigV4.sign(
            method: "PUT",
            endpoint: configuration.endpoint,
            pathSegments: [configuration.bucket] + keySegments,
            extraHeaders: ["content-type": contentType],
            payloadHash: payloadHash,
            accessKeyId: configuration.accessKeyId,
            secretAccessKey: secret,
            region: configuration.region,
            date: now
        )
        let response = try await transport.send(url: signed.url, method: signed.method, headers: signed.headers, body: data)
        guard (200...299).contains(response.status) else {
            throw R2ValidationError.httpStatus(response.status, testing: false)
        }
        return try R2Validator.publicObjectURL(baseUrl: configuration.publicBaseUrl, objectKey: objectKey)
    }
}

@MainActor final class R2UploadCoordinator: ObservableObject {
    enum Outcome: Equatable {
        case copiedExisting(URL)
        case uploaded(URL)
        case notConfigured
        case unavailable
        case failed(String)
    }

    private enum ContentSnapshot: Equatable, Sendable {
        case file(url: URL, size: Int, modificationTime: TimeInterval)
        case text(Data)
        case link(String)
    }

    @Published private(set) var uploadingIDs = Set<UUID>()
    @Published private(set) var testingConnection = false
    @Published var connectionStatus: String?
    @Published var connectionError: String?

    private let store: LibraryStore?
    let defaults: UserDefaults
    let secrets: any R2SecretStore
    private let transport: any R2HTTPTransport
    private let writeLink: (URL) -> Bool
    private let now: @Sendable () -> Date
    private let makeToken: @Sendable () -> String
    private var inFlight = [UUID: Task<Void, Never>]()
    private var testTask: Task<Void, Never>?

    init(
        store: LibraryStore?,
        defaults: UserDefaults,
        secrets: any R2SecretStore,
        transport: any R2HTTPTransport = URLSessionR2Transport(),
        writeLink: ((URL) -> Bool)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String = { R2Validator.randomToken() }
    ) {
        self.store = store
        self.defaults = defaults
        self.secrets = secrets
        self.transport = transport
        self.writeLink = writeLink ?? { ClipboardTransfer.write(ClipboardTransfer.linkItems([$0.absoluteString])) }
        self.now = now
        self.makeToken = makeToken
    }

    var configuration: R2Configuration { R2Preferences.load(from: defaults) }
    var hasSavedSecret: Bool { secrets.hasSecret() }
    var isConfigured: Bool {
        guard hasSavedSecret else { return false }
        return (try? R2Validator.validate(configuration)) != nil
    }

    func saveConfiguration(_ value: R2Configuration) {
        R2Preferences.save(value, to: defaults)
        connectionStatus = nil
        connectionError = nil
        objectWillChange.send()
    }

    func saveSecret(_ value: String) throws {
        try secrets.saveSecret(value)
        connectionStatus = nil
        connectionError = nil
        objectWillChange.send()
    }

    func clearSecret() throws {
        try secrets.clearSecret()
        connectionStatus = nil
        connectionError = nil
        objectWillChange.send()
    }

    func testConnection(draftSecret: String = "", completion: ((Result<Void, Error>) -> Void)? = nil) {
        testTask?.cancel()
        connectionStatus = nil
        connectionError = nil
        let validated: ValidatedR2Configuration
        let secret: String
        do {
            validated = try R2Validator.validate(configuration)
            let trimmedDraft = draftSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDraft.isEmpty {
                secret = trimmedDraft
            } else if let saved = try secrets.readSecret() {
                secret = saved
            } else {
                throw R2ValidationError.missingSecretAccessKey
            }
        } catch {
            connectionError = error.localizedDescription
            completion?(.failure(error))
            return
        }
        testingConnection = true
        let transport = self.transport
        let timestamp = now()
        testTask = Task { [weak self] in
            do {
                try await R2Client.testConnection(configuration: validated, secretAccessKey: secret, transport: transport, now: timestamp)
                guard !Task.isCancelled, let self else { return }
                self.testingConnection = false
                self.connectionError = nil
                self.connectionStatus = L("Connected to Cloudflare R2")
                completion?(.success(()))
            } catch is CancellationError {
                self?.testingConnection = false
            } catch {
                guard let self else { return }
                self.testingConnection = false
                self.connectionStatus = nil
                self.connectionError = error.localizedDescription
                completion?(.failure(error))
            }
        }
    }

    func cancelAll() {
        testTask?.cancel()
        testTask = nil
        testingConnection = false
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        uploadingIDs.removeAll()
    }

    func uploadLatest(completion: ((Outcome) -> Void)? = nil) {
        guard let store else { completion?(.unavailable); return }
        let query = LibraryQuery(scope: .shelf, sort: .newest)
        let recentQuery = LibraryQuery(scope: .recent, sort: .newest)
        guard let id = (try? store.query(query, limit: 1).first?.id) ?? (try? store.query(recentQuery, limit: 1).first?.id) else {
            completion?(.unavailable)
            return
        }
        upload(id, forceReupload: false, completion: completion)
    }

    func upload(_ id: UUID, forceReupload: Bool = false, completion: ((Outcome) -> Void)? = nil) {
        guard let store, let record = try? store.item(id), record.deletedAt == nil else {
            completion?(.unavailable)
            return
        }
        if !forceReupload, let existing = record.uploadedURL,
           let url = URL(string: existing), url.scheme?.lowercased() == "https" {
            let outcome: Outcome = writeLink(url) ? .copiedExisting(url) : .failed(L("Cloudflare R2 connection failed"))
            completion?(outcome)
            return
        }
        if inFlight[id] != nil { return }
        let validated: ValidatedR2Configuration
        let secret: String
        do {
            guard hasSavedSecret else { throw R2ValidationError.notConfigured }
            validated = try R2Validator.validate(configuration)
            guard let storedSecret = try secrets.readSecret(), !storedSecret.isEmpty else {
                throw R2ValidationError.notConfigured
            }
            secret = storedSecret
        } catch R2ValidationError.notConfigured {
            completion?(.notConfigured)
            return
        } catch {
            completion?(.failed(error.localizedDescription))
            return
        }

        guard let snapshot = Self.snapshot(for: record, files: store.files) else {
            completion?(.unavailable)
            return
        }

        uploadingIDs.insert(id)
        let transport = self.transport
        let now = self.now
        let makeToken = self.makeToken
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome: Outcome
            do {
                let uploadedURL = try await Task.detached(priority: .userInitiated) {
                    let payload: Data
                    let ext: String
                    switch snapshot {
                    case let .file(url, size, _):
                        guard size <= R2Validator.maximumUploadBytes else { throw R2ValidationError.fileTooLarge }
                        payload = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard payload.count <= R2Validator.maximumUploadBytes else { throw R2ValidationError.fileTooLarge }
                        ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
                    case let .text(bytes):
                        payload = bytes
                        ext = "txt"
                    case let .link(urlString):
                        payload = Data(urlString.utf8)
                        ext = "txt"
                    }
                    let key = R2Validator.makeObjectKey(prefix: validated.keyPrefix, token: makeToken(), fileExtension: ext)
                    let contentType = R2Validator.contentType(forExtension: ext)
                    return try await R2Client.uploadObject(
                        data: payload,
                        contentType: contentType,
                        objectKey: key,
                        configuration: validated,
                        secretAccessKey: secret,
                        transport: transport,
                        now: now()
                    )
                }.value

                try Task.checkCancellation()
                // Re-verify the live record has not been deleted or edited while
                // uploading so an outdated upload never attaches to new content.
                guard let current = try store.item(id), current.deletedAt == nil,
                      Self.matches(snapshot, record: current, files: store.files) else {
                    finish(id, outcome: .unavailable, completion: completion)
                    return
                }
                try store.recordUpload(id, url: uploadedURL.absoluteString)
                outcome = writeLink(uploadedURL) ? .uploaded(uploadedURL) : .failed(L("Cloudflare R2 connection failed"))
            } catch is CancellationError {
                inFlight.removeValue(forKey: id)
                uploadingIDs.remove(id)
                return
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            finish(id, outcome: outcome, completion: completion)
        }
        inFlight[id] = task
    }

    private func finish(_ id: UUID, outcome: Outcome, completion: ((Outcome) -> Void)?) {
        inFlight.removeValue(forKey: id)
        uploadingIDs.remove(id)
        completion?(outcome)
    }

    private static func snapshot(for record: LibraryRecord, files: HistoryFiles) -> ContentSnapshot? {
        switch record.kind {
        case .image:
            guard let url = record.fileURL, files.isRegularFile(url),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            return .file(url: url, size: size, modificationTime: modified)
        case .text:
            guard let text = record.text, !text.isEmpty else { return nil }
            return .text(Data(text.utf8))
        case .link:
            guard let link = record.originalURL, !link.isEmpty else { return nil }
            return .link(link)
        }
    }

    private static func matches(_ snapshot: ContentSnapshot, record: LibraryRecord, files: HistoryFiles) -> Bool {
        switch (snapshot, record.kind) {
        case let (.file(expectedURL, expectedSize, expectedMod), .image):
            guard let currentURL = record.fileURL, files.isRegularFile(currentURL),
                  let values = try? currentURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let currentSize = values.fileSize else { return false }
            if currentURL == expectedURL {
                let currentMod = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                return currentSize == expectedSize && abs(currentMod - expectedMod) < 0.000_001
            }
            // Pinning or retaining an external screenshot creates an identical owned copy.
            return record.originalPath == expectedURL.path && currentSize == expectedSize
        case let (.text(expectedBytes), .text):
            return Data((record.text ?? "").utf8) == expectedBytes
        case let (.link(expectedURL), .link):
            return record.originalURL == expectedURL
        default:
            return false
        }
    }
}
