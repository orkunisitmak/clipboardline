import Foundation
import Darwin
import Network
import Security

enum PublicLinkError: Error, Equatable {
    case blockedURL, blockedAddress, resolution, timeout, invalidResponse, tooLarge, truncated, redirects, unsupportedEncoding, trust
}

/// Numeric addresses, never hostnames. Endpoint creation below uses the typed
/// IPv4/IPv6 cases so Network.framework cannot perform a second DNS lookup.
struct PublicLinkAddress: Equatable, Sendable {
    let text: String
    let bytes: [UInt8]

    init?(_ value: String) {
        guard !value.contains("%"), !value.contains("\0") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, value, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            let canonical = bytes.map(String.init).joined(separator: ".")
            guard value == canonical else { return nil }
            text = canonical; self.bytes = bytes; return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, value, &v6) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        text = String(cString: buffer); bytes = withUnsafeBytes(of: &v6) { Array($0) }
    }

    var isPublic: Bool {
        if bytes.count == 4 {
            let a = bytes[0], b = bytes[1], c = bytes[2]
            return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) ||
                (a == 172 && (16...31).contains(b)) ||
                (a == 192 && (b == 0 || b == 168 || (b == 88 && c == 99))) ||
                (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
                (a == 203 && b == 0 && c == 113))
        }
        // Permit global unicast only. Exclude IETF special-purpose 2001::/23,
        // documentation, and 6to4 (whose embedded IPv4 could be private).
        return bytes.count == 16 && bytes[0] & 0xe0 == 0x20 &&
            !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2) &&
            !Array(bytes.prefix(4)).elementsEqual([0x20, 0x01, 0x0d, 0xb8]) &&
            !Array(bytes.prefix(2)).elementsEqual([0x20, 0x02]) &&
            !(bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0)
    }

    var endpointHost: NWEndpoint.Host {
        if bytes.count == 4 { return .ipv4(IPv4Address(text)!) }
        return .ipv6(IPv6Address(text)!)
    }
}

struct PublicLinkDestination: Equatable, Sendable {
    let url: URL
    let hostname: String
    let requestTarget: String

    init?(_ input: URL) {
        guard input.absoluteString.utf8.count <= 8192,
              var c = URLComponents(url: input, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, let host = c.host?.lowercased(),
              host.utf8.count <= 253, host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              host.contains("."), !host.hasSuffix("."),
              !["local", "localhost", "internal", "home", "arpa", "lan", "corp", "localdomain", "onion", "test", "invalid", "example", "alt"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              labels.last?.contains(where: { $0.isLetter }) == true else { return nil }
        let secretNames: Set<String> = ["token", "accesstoken", "refreshtoken", "idtoken", "auth", "authorization", "authentication", "authtoken", "password", "secret", "clientsecret", "key", "apikey", "accesskeyid", "signature", "sig", "code", "session", "sessionid", "credential", "credentials", "jwt", "bearer", "state", "policy", "keypairid", "verifier"]
        guard !(c.queryItems ?? []).contains(where: {
            let name = $0.name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            return secretNames.contains(name) || name.hasPrefix("xamz") || name.hasPrefix("xgoog") || name.hasPrefix("oauth")
        }) else { return nil }
        c.scheme = "https"; c.host = host; c.port = nil; c.fragment = nil
        if c.percentEncodedPath.isEmpty { c.percentEncodedPath = "/" }
        let target = c.percentEncodedPath + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard target.utf8.allSatisfy({ (0x21...0x7e).contains($0) }), let url = c.url else { return nil }
        self.url = url; hostname = host; requestTarget = target
    }
}

struct PublicLinkConnectionPlan: Equatable, Sendable {
    let destination: PublicLinkDestination
    let address: PublicLinkAddress
    var tlsServerName: String { destination.hostname }
    var certificateHostname: String { destination.hostname }
    var request: Data {
        Data(("GET \(destination.requestTarget) HTTP/1.1\r\nHost: \(destination.hostname)\r\n" +
              "User-Agent: ClipBoardLine LinkPreview\r\nAccept: text/html,application/xhtml+xml,application/json,image/*\r\n" +
              "Accept-Encoding: identity\r\nConnection: close\r\n\r\n").utf8)
    }
    init(destination: PublicLinkDestination, address: PublicLinkAddress) throws {
        guard address.isPublic else { throw PublicLinkError.blockedAddress }
        self.destination = destination; self.address = address
    }
}

struct PublicLinkHTTPResponse: Equatable, Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/// A bounded HTTP/1 parser. No compression, content execution, cookie storage,
/// authentication, proxy, browser or subresource fetching is involved.
struct PublicLinkHTTPParser {
    private enum Phase { case headers, fixed(Int), untilClose, chunkSize, chunkBody(Int), chunkEnd, trailers, done }
    private var phase = Phase.headers
    private var pending = Data(), body = Data()
    private var status = 0, headers: [String: String] = [:], wireBytes = 0, trailerBytes = 0
    private let limit: Int
    init(limit: Int) { self.limit = max(1, min(limit, 5 * 1024 * 1024)) }

    mutating func append(_ data: Data, end: Bool = false) throws -> PublicLinkHTTPResponse? {
        wireBytes += data.count
        guard wireBytes <= limit * 2 + 65_536 else { throw PublicLinkError.tooLarge }
        pending.append(data)
        while true {
            switch phase {
            case .headers:
                guard let split = pending.range(of: Data("\r\n\r\n".utf8)) else {
                    guard pending.count <= 32_768 else { throw PublicLinkError.tooLarge }
                    if end { throw PublicLinkError.truncated }; return nil
                }
                guard split.upperBound <= 32_768 else { throw PublicLinkError.tooLarge }
                let head = pending.subdata(in: 0..<split.lowerBound)
                pending = Data(pending[split.upperBound...])
                try parseHeaders(head)
            case .fixed(let count):
                let take = min(count, pending.count); try consumeBody(take)
                if take == count { phase = .done } else { phase = .fixed(count - take); if end { throw PublicLinkError.truncated }; return nil }
            case .untilClose:
                try consumeBody(pending.count)
                if end { phase = .done } else { return nil }
            case .chunkSize:
                guard let line = try readLine(maximum: 1024) else { if end { throw PublicLinkError.truncated }; return nil }
                let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard !sizeText.isEmpty, sizeText.count <= 8,
                      sizeText.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let size = Int(sizeText, radix: 16), size <= limit - body.count else { throw PublicLinkError.tooLarge }
                phase = size == 0 ? .trailers : .chunkBody(size)
            case .chunkBody(let count):
                let take = min(count, pending.count); try consumeBody(take)
                if take == count { phase = .chunkEnd } else { phase = .chunkBody(count - take); if end { throw PublicLinkError.truncated }; return nil }
            case .chunkEnd:
                guard pending.count >= 2 else { if end { throw PublicLinkError.truncated }; return nil }
                guard pending.prefix(2).elementsEqual([13, 10]) else { throw PublicLinkError.invalidResponse }
                pending = Data(pending.dropFirst(2)); phase = .chunkSize
            case .trailers:
                guard let line = try readLine(maximum: 8192) else { if end { throw PublicLinkError.truncated }; return nil }
                trailerBytes += line.utf8.count + 2
                guard trailerBytes <= 8192 else { throw PublicLinkError.tooLarge }
                if line.isEmpty { phase = .done }
                // Trailers never override any header or redirect destination.
            case .done:
                guard pending.isEmpty else { throw PublicLinkError.invalidResponse }
                return PublicLinkHTTPResponse(status: status, headers: headers, body: body)
            }
        }
    }

    private mutating func consumeBody(_ count: Int) throws {
        guard count <= limit - body.count else { throw PublicLinkError.tooLarge }
        body.append(pending.prefix(count)); pending = Data(pending.dropFirst(count))
    }
    private mutating func readLine(maximum: Int) throws -> String? {
        guard let split = pending.range(of: Data([13, 10])) else {
            guard pending.count <= maximum else { throw PublicLinkError.tooLarge }; return nil
        }
        guard split.lowerBound <= maximum, let line = String(data: pending.prefix(split.lowerBound), encoding: .ascii) else { throw PublicLinkError.invalidResponse }
        pending = Data(pending[split.upperBound...]); return line
    }
    private mutating func parseHeaders(_ data: Data) throws {
        guard let head = String(data: data, encoding: .ascii) else { throw PublicLinkError.invalidResponse }
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        guard first.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(first[0]), first[1].count == 3,
              let code = Int(first[1]), (200...599).contains(code), lines.count <= 65 else { throw PublicLinkError.invalidResponse }
        status = code
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw PublicLinkError.invalidResponse }
            let name = String(line[..<colon]).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { throw PublicLinkError.invalidResponse }
            if ["content-length", "transfer-encoding", "content-encoding", "location"].contains(name), headers[name] != nil { throw PublicLinkError.invalidResponse }
            headers[name] = value
        }
        if let encoding = headers["content-encoding"], encoding.lowercased() != "identity" { throw PublicLinkError.unsupportedEncoding }
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw PublicLinkError.invalidResponse }
            phase = .chunkSize
        } else if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length), count <= limit else { throw PublicLinkError.tooLarge }
            phase = .fixed(count)
        } else { phase = .untilClose }
    }
}

private final class PublicLinkCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); guard self.result == nil else { lock.unlock(); return }
        self.result = result; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}

enum PublicLinkResolver {
    static func resolve(_ hostname: String) async throws -> [PublicLinkAddress] {
        let completion = PublicLinkCompletion<[PublicLinkAddress]>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                completion.attach(continuation)
                DispatchQueue.global(qos: .utility).async {
                    var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP; hints.ai_flags = AI_NUMERICSERV
                    var result: UnsafeMutablePointer<addrinfo>?
                    guard getaddrinfo(hostname, "443", &hints, &result) == 0, let first = result else { completion.finish(.failure(PublicLinkError.resolution)); return }
                    defer { freeaddrinfo(first) }
                    var addresses = [PublicLinkAddress](), cursor: UnsafeMutablePointer<addrinfo>? = first
                    while let row = cursor {
                        guard addresses.count < 32, let socketAddress = row.pointee.ai_addr else { completion.finish(.failure(PublicLinkError.resolution)); return }
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        guard getnameinfo(socketAddress, row.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                              let address = PublicLinkAddress(String(cString: host)) else { completion.finish(.failure(PublicLinkError.blockedAddress)); return }
                        addresses.append(address); cursor = row.pointee.ai_next
                    }
                    completion.finish(.success(addresses))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { completion.finish(.failure(PublicLinkError.timeout)) }
            }
        }, onCancel: { completion.finish(.failure(CancellationError())) })
    }
}

enum PublicLinkTLS {
    static func policy(hostname: String) -> SecPolicy { SecPolicyCreateSSL(true, hostname as CFString) }
    static func evaluate(_ trust: SecTrust, hostname: String) -> Bool {
        // No custom anchors, exceptions or "accept anyway" path. Prevent trust
        // evaluation from fetching attacker-selected AIA/OCSP URLs outside this
        // transport; the server must supply a verifiable chain to system roots.
        guard SecTrustSetPolicies(trust, policy(hostname: hostname)) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

private final class PublicLinkExchange: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.clipboardline.public-link.transport", qos: .utility)
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<PublicLinkHTTPResponse, Error>?
    private var cancelled = false
    private var parser: PublicLinkHTTPParser
    init(limit: Int) { parser = PublicLinkHTTPParser(limit: limit) }
    func run(_ plan: PublicLinkConnectionPlan) async throws -> PublicLinkHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let tls = NWProtocolTLS.Options()
                    sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, plan.tlsServerName)
                    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
                    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                        let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                        complete(PublicLinkTLS.evaluate(reference, hostname: plan.certificateHostname))
                    }, DispatchQueue.global(qos: .utility))
                    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
                    let connection = NWConnection(host: plan.address.endpointHost, port: 443, using: parameters)
                    self.connection = connection
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.send(content: plan.request, completion: .contentProcessed { error in
                                if let error { self.finish(.failure(error)) } else { self.receive() }
                            })
                        case .failed(let error), .waiting(let error): self.finish(.failure(error))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 12) { self.finish(.failure(PublicLinkError.timeout)) }
                }
            }
        }, onCancel: { self.queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) } })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            do {
                if let response = try self.parser.append(data ?? Data(), end: complete) { self.finish(.success(response)) }
                else if let error { self.finish(.failure(error)) }
                else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<PublicLinkHTTPResponse, Error>) {
        guard let continuation else { return }; self.continuation = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        continuation.resume(with: result)
    }
}

struct PublicLinkResponse: Equatable, Sendable {
    let url: URL
    let headers: [String: String]
    let body: Data
}

struct PublicLinkNetwork: Sendable {
    typealias Resolve = @Sendable (String) async throws -> [PublicLinkAddress]
    typealias Exchange = @Sendable (PublicLinkConnectionPlan, Int) async throws -> PublicLinkHTTPResponse
    private let resolve: Resolve
    private let exchange: Exchange
    init(resolve: @escaping Resolve = { try await PublicLinkResolver.resolve($0) },
         exchange: @escaping Exchange = { plan, limit in try await PublicLinkExchange(limit: limit).run(plan) }) {
        self.resolve = resolve; self.exchange = exchange
    }
    func fetch(_ url: URL, limit: Int, allowed: @Sendable (URL) -> Bool = { _ in true }) async throws -> PublicLinkResponse {
        guard (1...5 * 1024 * 1024).contains(limit) else { throw PublicLinkError.tooLarge }
        var current = url
        for hop in 0...3 {
            try Task.checkCancellation()
            guard let destination = PublicLinkDestination(current), allowed(destination.url) else { throw PublicLinkError.blockedURL }
            let addresses = try await resolve(destination.hostname)
            try Task.checkCancellation()
            guard !addresses.isEmpty, addresses.count <= 32, addresses.allSatisfy(\.isPublic), let address = addresses.first else { throw PublicLinkError.blockedAddress }
            let plan = try PublicLinkConnectionPlan(destination: destination, address: address)
            let response = try await exchange(plan, limit)
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard hop < 3, let location = response.headers["location"], location.utf8.count <= 8192,
                      let next = URL(string: location, relativeTo: destination.url)?.absoluteURL else { throw PublicLinkError.redirects }
                current = next; continue
            }
            guard response.status == 200, response.body.count <= limit else { throw PublicLinkError.invalidResponse }
            return PublicLinkResponse(url: destination.url, headers: response.headers, body: response.body)
        }
        throw PublicLinkError.redirects
    }
}

struct PublicLinkHTMLMetadata: Equatable, Sendable {
    let title: String?
    let author: String?
    let thumbnailURL: URL?

    init(data: Data, url: URL, contentType: String = "") throws {
        guard data.count <= 512 * 1024 else { throw PublicLinkError.tooLarge }
        let source = Self.decode(data, contentType: contentType)
        let html = Self.replacing(#"(?is)<!--.*?-->|<script\b[^>]*>.*?</script\s*>|<style\b[^>]*>.*?</style\s*>"#, in: source, with: "")
        let tags = try NSRegularExpression(pattern: #"(?is)<meta\b([^>]{0,8192})>"#)
        let attributes = try NSRegularExpression(pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
        var metadata: [String: String] = [:]
        for tag in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(256) {
            guard let range = Range(tag.range(at: 1), in: html) else { continue }
            let raw = String(html[range]); var values: [String: String] = [:]
            for attribute in attributes.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let key = Range(attribute.range(at: 1), in: raw),
                      let value = (2...4).compactMap({ Range(attribute.range(at: $0), in: raw) }).first else { continue }
                values[String(raw[key]).lowercased()] = Self.entities(String(raw[value]))
            }
            if let key = values["property"] ?? values["name"], let value = values["content"], metadata[key.lowercased()] == nil { metadata[key.lowercased()] = String(value.prefix(2000)) }
        }
        let titleTag = try NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.{0,8192}?)</title\s*>"#)
        let titleMatch = titleTag.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
            .flatMap { Range($0.range(at: 1), in: html) }.map { Self.entities(Self.replacing(#"<[^>]*>"#, in: String(html[$0]), with: "")) }
        title = Self.clean(metadata["og:title"] ?? metadata["twitter:title"] ?? titleMatch, limit: 500)
        author = Self.clean(metadata["author"] ?? metadata["og:site_name"], limit: 200)
        let image = metadata["og:image:secure_url"] ?? metadata["og:image"] ?? metadata["twitter:image"]
        thumbnailURL = image.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }.flatMap { PublicLinkDestination($0)?.url }
    }
    /// Encoding sniffing order, as in windows/lib/network.cjs decodeHTML: UTF-8 BOM, Content-Type charset,
    /// XML declaration (XHTML only), early <meta charset>. Unknown labels fall through; undeclared bytes
    /// that are not UTF-8 are windows-1252. The first 2048 bytes are read as Latin-1 only to find a label.
    static func decode(_ data: Data, contentType: String = "") -> String {
        let head = String(data: data.prefix(2048), encoding: .isoLatin1) ?? ""
        func labels(_ pattern: String, in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        }
        let hasBOM = data.starts(with: [0xef, 0xbb, 0xbf]), bom = hasBOM ? ["utf-8"] : []
        let xml = contentType.range(of: "application/xhtml+xml", options: .caseInsensitive) == nil ? [] :
            Array(labels(#"^\s*<\?xml[^>]*\sencoding\s*=\s*["']([\w.:-]+)"#, in: head).prefix(1))
        // A meta declaration of UTF-16 cannot be true for ASCII-compatible markup; HTML treats it as UTF-8.
        let meta = labels(#"<meta[^>]*[\s"';]charset\s*=\s*["']?([\w.:-]+)"#, in: head).map { $0.lowercased().hasPrefix("utf-16") ? "utf-8" : $0 }
        let header = Array(labels(#"(?:^|;)\s*charset\s*=\s*["']?([\w.:-]+)"#, in: contentType).prefix(1))
        let declared: [String] = bom + header + xml + meta
        if let encoding = declared.lazy.compactMap(Self.encoding(for:)).first {
            if encoding == .utf8 { return String(decoding: hasBOM ? data.dropFirst(3) : data, as: UTF8.self) }
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
    private static func encoding(for label: String) -> String.Encoding? {
        // WHATWG maps the Latin-1 and Latin-5 labels to their Windows supersets.
        let aliases = ["iso-8859-1": "windows-1252", "latin1": "windows-1252", "us-ascii": "windows-1252", "ascii": "windows-1252", "iso-8859-9": "windows-1254", "latin5": "windows-1254"]
        let name = label.lowercased(), converted = CFStringConvertIANACharSetNameToEncoding((aliases[name] ?? name) as CFString)
        guard converted != 0xFFFF_FFFF else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
    }
    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }
    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        // Drop Cc and the bidirectional marks, overrides, embeddings and isolates that can reorder a title to spoof another one.
        // CharacterSet.controlCharacters also holds Cf, which includes the joiners emoji and Persian text need.
        let clean = value.unicodeScalars.filter {
            let bidi = [0x061C, 0x200E, 0x200F].contains($0.value) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
            return ($0.properties.generalCategory != .control && !bidi) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let result = String(String.UnicodeScalarView(clean)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return result.isEmpty ? nil : String(result.prefix(limit))
    }
    private static let namedEntities = ["amp": "&", "quot": "\"", "lt": "<", "gt": ">", "apos": "'", "nbsp": " ", "ccedil": "ç", "Ccedil": "Ç", "ouml": "ö", "Ouml": "Ö", "uuml": "ü", "Uuml": "Ü", "gbreve": "ğ", "Gbreve": "Ğ", "scedil": "ş", "Scedil": "Ş", "inodot": "ı", "Idot": "İ", "acirc": "â", "icirc": "î", "ucirc": "û", "auml": "ä", "Auml": "Ä", "szlig": "ß", "eacute": "é", "Eacute": "É", "egrave": "è", "agrave": "à", "aacute": "á", "iacute": "í", "oacute": "ó", "uacute": "ú", "ntilde": "ñ", "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£"]

    private static func entities(_ value: String) -> String {
        let named = namedEntities, names = named.keys.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: #"&(#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|\#(names));"#) else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range, in: result), let nameRange = Range(match.range(at: 1), in: value) else { continue }
            let name = String(value[nameRange]); var replacement = named[name]
            if name.hasPrefix("#x") || name.hasPrefix("#X"), let number = UInt32(name.dropFirst(2), radix: 16), let scalar = UnicodeScalar(number), scalar.properties.generalCategory != .control { replacement = String(scalar) }
            else if name.hasPrefix("#"), let number = UInt32(name.dropFirst()), let scalar = UnicodeScalar(number), scalar.properties.generalCategory != .control { replacement = String(scalar) }
            if let replacement { result.replaceSubrange(whole, with: replacement) }
        }
        return result
    }
}
