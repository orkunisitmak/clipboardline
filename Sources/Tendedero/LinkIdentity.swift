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
              (c.port ?? 0) <= 65535 else { return nil }
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
