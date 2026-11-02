import Foundation
import Network
import Security
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class PublicLinkPolicyTests: HistoryTestCase {
    func testAddressClassificationRejectsPrivateTransitionAndNoncanonicalForms() throws {
        for value in ["0.1.2.3", "10.1.2.3", "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.254", "192.0.0.1", "192.0.2.1", "192.168.0.1", "198.18.1.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "::", "::1", "::ffff:8.8.8.8", "fc00::1", "fe80::1", "ff02::1", "64:ff9b::7f00:1", "2001::1", "2001:20::1", "2001:db8::1", "2002:7f00:1::", "3fff::1"] {
            XCTAssertFalse(try XCTUnwrap(PublicLinkAddress(value)).isPublic, value)
        }
        for value in ["8.8.8.8", "93.184.216.34", "100.63.255.254", "100.128.0.1", "172.32.0.1", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertTrue(try XCTUnwrap(PublicLinkAddress(value)).isPublic, value)
        }
        for value in ["127.1", "2130706433", "0x7f000001", "0177.0.0.1", "127.000.0.1", "fe80::1%en0", "public.example.org"] { XCTAssertNil(PublicLinkAddress(value), value) }
    }

    func testDestinationRequiresNamedHTTPSAndStripsFragmentWithoutLeakingSecrets() throws {
        let syntheticUserInfo = "synthetic-user" + ":" + "synthetic-password" + "@"
        for value in ["http://example.com/a", "https://127.1/a", "https://8.8.8.8/a", "https://[2606:4700::1111]/a", "https://" + syntheticUserInfo + "example.com/a", "https://example.com:8443/a", "https://localhost/a", "https://host.local/a", "https://host.internal/a", "https://host.home.arpa/a", "https://host.onion/a", "https://host.invalid/a", "https://example.com./a", "https://-bad.example.com/a", "https://example.com/?%74oken=secret", "https://example.com/?X-Amz-Signature=secret", "https://example.com/?api_key=secret", "https://example.com/?api.key=secret", "https://example.com/?session.id=secret", "https://example.com/?api%CC%81.key=secret", "https://example.com/?accessToken=secret", "https://example.com/?sessionId=secret"] {
            XCTAssertNil(PublicLinkDestination(try XCTUnwrap(URL(string: value))), value)
        }
        let destination = try XCTUnwrap(PublicLinkDestination(URL(string: "https://Example.com:443/articles?q=hello%20world#private-fragment")!))
        XCTAssertEqual(destination.hostname, "example.com")
        XCTAssertEqual(destination.url.absoluteString, "https://example.com/articles?q=hello%20world")
        XCTAssertEqual(destination.requestTarget, "/articles?q=hello%20world")
    }

    func testPinnedEndpointUsesNumericCaseButTLSAndHostHeaderUseOriginalHostname() throws {
        let destination = try XCTUnwrap(PublicLinkDestination(URL(string: "https://public.example.org/path")!))
        let address = try XCTUnwrap(PublicLinkAddress("93.184.216.34"))
        let plan = try PublicLinkConnectionPlan(destination: destination, address: address)
        if case .ipv4 = plan.address.endpointHost {} else { XCTAssertTrue(false, "Must never create a hostname endpoint") }
        XCTAssertEqual(plan.tlsServerName, "public.example.org"); XCTAssertEqual(plan.certificateHostname, "public.example.org")
        let properties = try XCTUnwrap(SecPolicyCopyProperties(PublicLinkTLS.policy(hostname: plan.certificateHostname)) as? [String: Any])
        XCTAssertEqual(properties["SecPolicyName"] as? String, "public.example.org")
        let request = String(decoding: plan.request, as: UTF8.self)
        XCTAssertTrue(request.contains("Host: public.example.org\r\n")); XCTAssertTrue(request.contains("Accept-Encoding: identity\r\n"))
        XCTAssertFalse(request.contains("Authorization:")); XCTAssertFalse(request.contains("Cookie:")); XCTAssertFalse(request.contains("93.184.216.34"))
        XCTAssertThrowsError(try PublicLinkConnectionPlan(destination: destination, address: PublicLinkAddress("127.0.0.1")!))
    }

    func testTLSRejectsAnUntrustedSelfSignedCertificateWithoutChangingSystemTrust() throws {
        // Public DER fixture only. Its generated private key was discarded.
        let untrustedPublicCertificateDER = "MIICtjCCAZ4CCQDcBX9bSTbs6TANBgkqhkiG9w0BAQsFADAdMRswGQYDVQQDDBJwdWJsaWMuZXhhbXBsZS5vcmcwHhcNMjYxMDE5MTIyMDIyWhcNMzYxMDE2MTIyMDIyWjAdMRswGQYDVQQDDBJwdWJsaWMuZXhhbXBsZS5vcmcwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDH0zEGIWAoYwZuw7uP3FTUJneEguHHcstRYUCRSTnjRU4aPm8KpcRiWsiezLMOs15GGDyzL0s1Th7LDiHRH2oMxbaWClK6VUZK6uWtNfo12zva1OcralZNaRA7aubN40f/b631CM/1Fk47F+l8ZdjRvYpyJvIYdHaSlHtbUKxkLWFmmjjkGrdaf5j4ARhdqnpkqZxjqzHJm4hrjHrE81EIpXZ8HpZjSDStRcmF6jsRFLtBLw+PlMTVPS3v0lt/g0L5WaO9ZWtQ+E3nGgjbGoD/EgQrIpffGh6VnA0xZpzPeJQ8X1l8KpqTM+S/tp1Vze6MNb+rOUOOdwsUfnDJbYBZAgMBAAEwDQYJKoZIhvcNAQELBQADggEBADycxGDwyJHLcJvrchC6VExa7TCXO8PkgiwOhFxUVXFUsKLbmhxJ6QoNIC/gj3LWQ/AsvDr3kGFW6SNsYhAeB7XLR7izAglGgvlcOGtH2QCK6uEW97PrbNDao+mUqBP/JKsDxPh2SxWVE3foj0Dsa/Wm9jHBBCLZvCkygYqaKfhyWmXsp6mSTHCVvHpMiIS+UKOKevo3ur8xfonPKVstubZiweA0dn/e28pA0ztvfQss3vI/EwavfRh1U7Gy2pHYDB9b6NkxLRn/cMYKdINPjTOuj7iRMxLg7znJldnzKMf6PGf/ek7rn2AFIPHg4IpKX2hbKgSDalazKQUbW90HG7I="
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, try XCTUnwrap(Data(base64Encoded: untrustedPublicCertificateDER)) as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, PublicLinkTLS.policy(hostname: "public.example.org"), &trust), errSecSuccess)
        XCTAssertFalse(PublicLinkTLS.evaluate(try XCTUnwrap(trust), hostname: "public.example.org"))
    }

    func testHTTPParserStreamsFixedChunkedAndConnectionCloseBodies() throws {
        for fixture in ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/html\r\n\r\nhello",
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;foo=bar\r\nhe\r\n3\r\nllo\r\n0\r\nX-Ignored: test\r\n\r\n",
                        "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\nhello"] {
            var parser = PublicLinkHTTPParser(limit: 5), response: PublicLinkHTTPResponse?
            let bytes = Array(fixture.utf8)
            for (index, byte) in bytes.enumerated() { response = try parser.append(Data([byte]), end: index == bytes.count - 1) ?? response }
            XCTAssertEqual(response?.status, 200); XCTAssertEqual(response?.body, Data("hello".utf8))
        }
    }

    func testHTTPParserRejectsAmbiguousTruncatedCompressedAndOversizedResponses() throws {
        for fixture in ["HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
                        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\nx",
                        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\nx",
                        "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhello!",
                        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhell",
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nhello!\r\n0\r\n\r\n",
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nxZZ0\r\n\r\n",
                        "HTTP/1.1 200 OK\r\n bad: folded\r\n\r\nx"] {
            var parser = PublicLinkHTTPParser(limit: 5)
            XCTAssertThrowsError(try parser.append(Data(fixture.utf8), end: true))
        }
        var parser = PublicLinkHTTPParser(limit: 5)
        XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: 32_769)))
    }

    func testHTMLDecodesCommonNamedEntitiesInTitles() throws {
        let url = URL(string: "https://public.example.org/page")!
        let parsed = try PublicLinkHTMLMetadata(data: Data("<title>G&uuml;nl&uuml;k &mdash; &Ccedil;i&ccedil;ek &unknown;</title>".utf8), url: url)
        XCTAssertEqual(parsed.title, "Günlük — Çiçek &unknown;")
        let hex = try PublicLinkHTMLMetadata(data: Data("<title>A&#x2014;B &#X2014;C &#8212;D</title>".utf8), url: url)
        XCTAssertEqual(hex.title, "A—B —C —D")
    }

    func testHTMLHonorsDeclaredMetaCharsetAndFallsBackToWindows1252() throws {
        let url = URL(string: "https://public.example.org/page")!, title = "Çiğdem Şişli İstanbul ıüö"
        func page(_ html: String, _ encoding: String.Encoding, type: String = "text/html") throws -> PublicLinkHTMLMetadata {
            try PublicLinkHTMLMetadata(data: try XCTUnwrap(html.data(using: encoding)), url: url, contentType: type)
        }
        XCTAssertEqual(try page("<title>\(title)</title>", .windowsCP1254, type: "text/html; charset=windows-1254").title, title)
        // The header wins over markup, an unknown header label falls through, and a UTF-8 BOM wins over a Latin-1 header.
        XCTAssertEqual(try page("<meta charset=\"utf-8\"><title>\(title)</title>", .windowsCP1254, type: "text/html; charset=iso-8859-9").title, title)
        XCTAssertEqual(try page("<meta charset=\"windows-1254\"><title>\(title)</title>", .windowsCP1254, type: "text/html; charset=bogus").title, title)
        XCTAssertEqual(try page("<title>\(title)</title>", .utf8, type: "text/html; x-charset=windows-1254; charset=utf-8").title, title)
        XCTAssertEqual(try page("\u{FEFF}<title>\(title)</title>", .utf8, type: "text/html; charset=iso-8859-1").title, title)
        // An XML declaration counts for XHTML only.
        XCTAssertEqual(try page("<?xml version=\"1.0\" encoding=\"windows-1254\"?><title>\(title)</title>", .utf8).title, title)
        XCTAssertEqual(try page("<?xml version=\"1.0\" encoding=\"windows-1254\"?><html><head><title>\(title)</title>", .windowsCP1254, type: "application/xhtml+xml").title, title)
        XCTAssertEqual(try page("<html><head><meta charset=\"ISO-8859-9\"><title>\(title)</title>", .windowsCP1254).title, title)
        XCTAssertEqual(try page("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1254\"><meta property=\"og:title\" content=\"\(title)\">", .windowsCP1254).title, title)
        // An unknown label falls through to the next declaration; a UTF-16 label in markup means UTF-8.
        XCTAssertEqual(try page("<meta charset=\"bogus\"><meta charset=\"windows-1254\"><title>\(title)</title>", .windowsCP1254).title, title)
        XCTAssertEqual(try page("<meta charset=\"utf-16\"><title>\(title)</title>", .utf8).title, title)
        XCTAssertEqual(try page("<meta name=\"description\" data-charset=\"windows-1254\"><meta charset=\"utf-8\"><title>\(title)</title>", .utf8).title, title)
        // Undeclared bytes that are not UTF-8 are windows-1252 like Windows, so 0x92 is a curly apostrophe, not a stripped control.
        XCTAssertEqual(try page("<title>Café ’s</title>", .windowsCP1252).title, "Café ’s")
        XCTAssertEqual(try page("<title>\(title)</title>", .utf8).title, title)
    }

    func testHTMLExtractsBoundedTextAndOneSafeThumbnailWithoutExecutingOrFollowingOtherResources() throws {
        let url = URL(string: "https://public.example.org/page")!
        let html = #"<html><!--<meta property='og:title' content='comment'>--><script><meta property='og:title' content='script'>fetch('http://localhost')</script><title>fallback</title><meta content='A &amp; B &#x1F30D;' property='og:title'><meta name=author content='Writer'><meta property='og:image' content='/cover.png'><img src='http://localhost/tracking'><iframe src='http://localhost'></iframe></html>"#
        let parsed = try PublicLinkHTMLMetadata(data: Data(html.utf8), url: url)
        XCTAssertEqual(parsed.title, "A & B 🌍"); XCTAssertEqual(parsed.author, "Writer"); XCTAssertEqual(parsed.thumbnailURL?.absoluteString, "https://public.example.org/cover.png")
        let blocked = try PublicLinkHTMLMetadata(data: Data(#"<title>Plain &lt;img&gt; &#0;</title><meta property='og:image' content='http://127.0.0.1/private'>"#.utf8), url: url)
        XCTAssertTrue(blocked.title?.contains("Plain <img>") == true); XCTAssertNil(blocked.thumbnailURL)
        let long = try PublicLinkHTMLMetadata(data: Data(("<meta property='og:title' content='" + String(repeating: "a", count: 3000) + "'>").utf8), url: url)
        XCTAssertEqual(long.title?.count, 500)
        XCTAssertThrowsError(try PublicLinkHTMLMetadata(data: Data(repeating: 65, count: 512 * 1024 + 1), url: url))
    }

    func testWhitespaceOnlyOpenGraphImageGivesNoThumbnailAndValidOneIsKept() throws {
        let url = URL(string: "https://public.example.org/page")!
        for blank in ["", "   ", "\n\t"] {
            XCTAssertNil(try PublicLinkHTMLMetadata(data: Data("<meta property='og:image' content='\(blank)'>".utf8), url: url).thumbnailURL)
        }
        let valid = try PublicLinkHTMLMetadata(data: Data("<meta property='og:image' content='/a.png'>".utf8), url: url)
        XCTAssertEqual(valid.thumbnailURL?.absoluteString, "https://public.example.org/a.png")
    }

    func testEmptyTitleCandidatesFallThroughToTheNextOne() throws {
        let url = URL(string: "https://public.example.org/page")!
        let twitter = try PublicLinkHTMLMetadata(data: Data("<title>Page</title><meta property='og:title' content='  '><meta name='twitter:title' content='Tweet'>".utf8), url: url)
        XCTAssertEqual(twitter.title, "Tweet")
        let page = try PublicLinkHTMLMetadata(data: Data("<title>Page</title><meta property='og:title' content=''><meta name='twitter:title' content=' '>".utf8), url: url)
        XCTAssertEqual(page.title, "Page")
    }
}

#if !STANDALONE_TESTS
private actor PublicLinkProbe {
    var hosts: [String] = [], plans: [PublicLinkConnectionPlan] = []
    let answers: [[PublicLinkAddress]], responses: [PublicLinkHTTPResponse]
    init(answers: [[PublicLinkAddress]], responses: [PublicLinkHTTPResponse]) { self.answers = answers; self.responses = responses }
    func resolve(_ host: String) throws -> [PublicLinkAddress] {
        hosts.append(host); guard hosts.count <= answers.count else { throw PublicLinkError.resolution }; return answers[hosts.count - 1]
    }
    func exchange(_ plan: PublicLinkConnectionPlan) throws -> PublicLinkHTTPResponse {
        plans.append(plan); guard plans.count <= responses.count else { throw PublicLinkError.invalidResponse }; return responses[plans.count - 1]
    }
}

final class PublicLinkNetworkAsyncTests: XCTestCase {
    private func client(_ probe: PublicLinkProbe) -> PublicLinkNetwork {
        PublicLinkNetwork(resolve: { try await probe.resolve($0) }, exchange: { plan, _ in try await probe.exchange(plan) })
    }
    func testAnyPrivateDNSAnswerPreventsEveryConnection() async throws {
        let probe = PublicLinkProbe(answers: [[PublicLinkAddress("93.184.216.34")!, PublicLinkAddress("100.64.0.1")!]], responses: [])
        do { _ = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100); XCTFail("Private DNS answer accepted") }
        catch { XCTAssertEqual(error as? PublicLinkError, .blockedAddress) }
        let count = await probe.plans.count; XCTAssertEqual(count, 0)
    }
    func testRedirectRebindingRevalidatesDNSBeforeSendingAnotherHTTPRequest() async throws {
        let probe = PublicLinkProbe(answers: [[PublicLinkAddress("93.184.216.34")!], [PublicLinkAddress("127.0.0.1")!]],
            responses: [PublicLinkHTTPResponse(status: 302, headers: ["location": "/next"], body: Data())])
        do { _ = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100); XCTFail("Rebinding accepted") }
        catch { XCTAssertEqual(error as? PublicLinkError, .blockedAddress) }
        let plans = await probe.plans, hosts = await probe.hosts
        XCTAssertEqual(plans.count, 1); XCTAssertEqual(hosts.count, 2)
    }
    func testPublicRedirectPinsEachAddressAndKeepsItsOwnTLSHostname() async throws {
        let probe = PublicLinkProbe(answers: [[PublicLinkAddress("93.184.216.34")!], [PublicLinkAddress("8.8.8.8")!]], responses: [
            PublicLinkHTTPResponse(status: 302, headers: ["location": "https://cdn.example.org/next"], body: Data()),
            PublicLinkHTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("done".utf8))])
        let result = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100)
        let plans = await probe.plans
        XCTAssertEqual(result.url.absoluteString, "https://cdn.example.org/next"); XCTAssertEqual(result.body, Data("done".utf8))
        XCTAssertEqual(plans.map(\.tlsServerName), ["public.example.org", "cdn.example.org"])
        XCTAssertEqual(plans.map { $0.address.text }, ["93.184.216.34", "8.8.8.8"])
    }
    func testUnsafeRedirectCannotResolveOrConnectAndHopBudgetIsEnforced() async throws {
        let syntheticUserInfo = "synthetic-user" + ":" + "synthetic-password" + "@"
        for location in ["http://public.example.org/plain", "https://127.0.0.1/secret", "https://" + syntheticUserInfo + "cdn.example.org/a"] {
            let probe = PublicLinkProbe(answers: [[PublicLinkAddress("93.184.216.34")!]], responses: [PublicLinkHTTPResponse(status: 302, headers: ["location": location], body: Data())])
            do { _ = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100); XCTFail("Unsafe redirect accepted") }
            catch { XCTAssertEqual(error as? PublicLinkError, .blockedURL) }
            let hosts = await probe.hosts, plans = await probe.plans; XCTAssertEqual(hosts.count, 1); XCTAssertEqual(plans.count, 1)
        }
        let probe = PublicLinkProbe(answers: Array(repeating: [PublicLinkAddress("93.184.216.34")!], count: 4), responses: Array(repeating: PublicLinkHTTPResponse(status: 302, headers: ["location": "/again"], body: Data()), count: 4))
        do { _ = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100); XCTFail("Unbounded redirect accepted") }
        catch { XCTAssertEqual(error as? PublicLinkError, .redirects) }
        let plans = await probe.plans; XCTAssertEqual(plans.count, 4)
    }
}
#endif
