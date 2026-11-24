import Foundation

enum LinkIdentity {
    static func standalone(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: value), normalized(url) != nil else { return nil }
        return url
    }
    static func youtubeID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let pieces = url.path.split(separator: "/").map(String.init)
        let candidate: String?
        if host == "youtu.be" || host == "www.youtu.be" { candidate = pieces.first }
        else if ["youtube.com","www.youtube.com","m.youtube.com","music.youtube.com"].contains(host) {
            if ["shorts","embed","live"].contains(pieces.first ?? ""), pieces.count > 1 { candidate = pieces[1] }
            else { candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value }
        } else { candidate = nil }
        guard let candidate, candidate.count == 11, candidate.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else { return nil }
        return candidate
    }
    static func normalized(_ url: URL) -> String? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http","https"].contains(c.scheme?.lowercased() ?? ""), let host = c.host, !host.isEmpty,
              (c.port ?? 0) <= 65535,
              (c.user ?? "").isEmpty, (c.password ?? "").isEmpty else { return nil }
        c.scheme = c.scheme?.lowercased(); c.host = host.lowercased()
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        var parameters = (c.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") && !["fbclid","gclid"].contains($0.name.lowercased()) }
        if let id = youtubeID(url) {
            c.scheme = "https"; c.host = "www.youtube.com"; c.path = "/watch"; c.port = nil
            parameters.removeAll { $0.name == "v" || $0.name == "si" }; parameters.insert(URLQueryItem(name: "v", value: id), at: 0)
        }
        if c.path.isEmpty { c.path = "/" }
        c.queryItems = parameters.isEmpty ? nil : parameters
        return c.url?.absoluteString
    }
    static func mayFetchMetadata(_ url: URL) -> Bool {
        PublicLinkDestination(url) != nil
    }
}

/// An HTML copy that is one link and nothing else, by the linked representation rows
/// of contracts/clipboard-admission.json. windows/lib/clipboard-policy.cjs follows
/// the same steps. This reads attributes only; it never interprets markup.
enum LinkedHTML {
    /// The destination when the copy's label is the anchor's own text, or when the copy
    /// has no label. A paragraph that merely contains a link is not a link.
    static func destination(html: String, label: String?) -> URL? {
        guard let anchor = singleAnchor(Array(html.utf16)) else { return nil }
        if let label, normalized(label) != normalized(decoded(withoutTags(anchor.text))) { return nil }
        return LinkIdentity.standalone(decoded(anchor.href))
    }
    private static func space(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D }
    /// The one anchor with a real href attribute and its content. Start tags are scanned
    /// attribute by attribute, so data-href or text inside another value is never the
    /// destination. Several links or an unterminated tag give nil.
    private static func singleAnchor(_ s: [UInt16]) -> (href: String, text: String)? {
        let lt: UInt16 = 0x3C, gt: UInt16 = 0x3E, slash: UInt16 = 0x2F, equals: UInt16 = 0x3D
        func at(_ index: Int) -> UInt16? { index < s.count ? s[index] : nil }
        func isA(_ c: UInt16?) -> Bool { c == 0x61 || c == 0x41 }
        func string(_ range: Range<Int>) -> String { String(decoding: s[range], as: UTF16.self) }
        var found: (href: String, text: String)?, i = 0
        while let open = s[i...].firstIndex(of: lt) {
            guard isA(at(open + 1)), let after = at(open + 2), space(after) || after == gt || after == slash else { i = open + 1; continue }
            var p = open + 2, href: String?
            while true {
                while let c = at(p), space(c) || c == slash { p += 1 }
                guard let c = at(p) else { return nil }
                if c == gt { p += 1; break }
                var start = p
                while let c = at(p), !space(c), c != equals, c != gt, c != slash { p += 1 }
                let name = string(start..<p).lowercased(); var value = ""
                while let c = at(p), space(c) { p += 1 }
                if at(p) == equals {
                    p += 1
                    while let c = at(p), space(c) { p += 1 }
                    guard let quote = at(p) else { return nil }
                    if quote == 0x22 || quote == 0x27 {
                        guard let end = s[(p + 1)...].firstIndex(of: quote) else { return nil }
                        value = string((p + 1)..<end); p = end + 1
                    } else {
                        start = p
                        while let c = at(p), !space(c), c != gt { p += 1 }
                        value = string(start..<p)
                    }
                }
                if name == "href", href == nil { href = value }
            }
            if let href {
                guard found == nil else { return nil }
                var end = p
                while true {
                    guard let close = s[end...].firstIndex(of: lt) else { end = s.count; break }
                    end = close
                    if at(end + 1) == slash, isA(at(end + 2)) {
                        guard let last = at(end + 3) else { break }
                        if last == gt || space(last) { break }
                    }
                    end += 1
                }
                found = (href, string(p..<end))
            }
            i = p
        }
        return found
    }
    private static func withoutTags(_ text: String) -> String {
        var result = String.UnicodeScalarView(), tag = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if !tag.isEmpty { if scalar == ">" { tag.removeAll() } else { tag.append(scalar) } }
            else if scalar == "<" { tag.append(scalar) } else { result.append(scalar) }
        }
        // An unclosed "<" is text, not a tag.
        result.append(contentsOf: tag)
        return String(result)
    }
    private static let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
    private static func decoded(_ text: String) -> String {
        var result = "", rest = Substring(text)
        while let start = rest.firstIndex(of: "&") {
            result += rest[..<start]; rest = rest[start...]
            let body = rest.dropFirst().prefix(9)
            guard let end = body.firstIndex(of: ";") else { result += "&"; rest = rest.dropFirst(); continue }
            let name = String(body[..<end]), replacement: String?
            if name.hasPrefix("#") {
                let digits = name.dropFirst(), hex = digits.first == "x" || digits.first == "X"
                let number = hex ? digits.dropFirst() : digits
                let valid = !number.isEmpty && number.count <= (hex ? 6 : 7) && number.allSatisfy { $0.isASCII && (hex ? $0.isHexDigit : $0.isNumber) }
                replacement = valid ? UInt32(number, radix: hex ? 16 : 10).flatMap { $0 > 0 ? Unicode.Scalar($0) : nil }.map { String($0) } : nil
            } else { replacement = entities[name] }
            if let replacement { result += replacement; rest = rest[rest.index(after: end)...] }
            else { result += "&"; rest = rest.dropFirst() }
        }
        return result + rest
    }
    private static func normalized(_ text: String) -> String {
        var result = String.UnicodeScalarView(), pending = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { pending = !result.isEmpty; continue }
            if pending { result.append(" "); pending = false }
            result.append(scalar)
        }
        return String(result)
    }
}
