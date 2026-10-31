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
        for value in ["http://example.com/a", "https://127.1/a", "https://8.8.8.8/a", "https://[2606:4700::1111]/a", "https://" + syntheticUserInfo + "example.com/a", "https://example.com:8443/a", "https://localhost/a", "https://host.local/a", "https://host.internal/a", "https://host.home.arpa/a", "https://host.onion/a", "https://host.invalid/a", "https://example.com./a", "https://-bad.example.com/a", "https://example.com/?%74oken=secret", "https://example.com/?X-Amz-Signature=secret", "https://example.com/?api_key=secret", "https://example.com/?accessToken=secret", "https://example.com/?sessionId=secret"] {
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

    func testParsingAWholeAllowedDocumentOfUnterminatedMarkupStaysInsideTheBudget() throws {
        // One unclosed tag forces a scanner to walk to the end of the document looking for the `>`
        // that never arrives, and every bad tag repeats that walk. Pinned here so the parsed work
        // cannot quietly grow back to the size of the download.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let markup = "<!doctype html><html><head><title>" + String(repeating: "<meta name=description content=unclosed ", count: 8_192)
        let page = markup + String(repeating: " ", count: 512 * 1024 - markup.count)
        let data = Data(page.utf8)
        XCTAssertEqual(data.count, 512 * 1024)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: data, url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertNil(metadata.title, "an unterminated document carries no readable metadata")
        XCTAssertLessThan(elapsedMilliseconds, 250, "parse of the full allowed document took \(elapsedMilliseconds) ms")
        XCTAssertEqual(metadata, try PublicLinkHTMLMetadata(data: data.prefix(PublicLinkHTMLMetadata.metadataWindowBytes), url: url),
                       "only the head window should be read, so the document tail must not change the result")
    }

    func testDenseUnterminatedMarkupWithOneClosingMarkerAtTheEndStaysInsideTheBudget() throws {
        // A single '>' at the very end defeats a "drop the dangling tail" rule: every earlier tag is
        // still open. A scanner pays for that walk once, a quantified pattern once per open tag.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let markup = String(repeating: "<meta name=description content=unclosed ", count: 8_192)
        let page = markup + String(repeating: " ", count: 512 * 1024 - markup.count - 1) + ">"
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertNil(metadata.title)
        XCTAssertLessThan(elapsedMilliseconds, 250, "dense unterminated markup took \(elapsedMilliseconds) ms")
    }

    func testUnterminatedTitleRunsStayInsideTheBudget() throws {
        // A run of `<title` with one `>` parked at the end costs a quantified pattern once per open
        // tag, because each one walks to that marker. A scanner walks it once and moves on.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let page = String(String(repeating: "<title", count: 88_000).prefix(512 * 1024 - 1)) + ">"
        let data = Data(page.utf8)
        XCTAssertEqual(data.count, 512 * 1024)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: data, url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertNil(metadata.title)
        XCTAssertLessThan(elapsedMilliseconds, 250, "unterminated title runs took \(elapsedMilliseconds) ms")
    }

    func testAnAttributeNameFarLongerThanAnyRealAttributeIsStillReadOnce() throws {
        // A pattern that bounds the length of an attribute name has to retry that bound at every start
        // position it tries, so a name longer than the bound costs the document by itself. A scanner
        // visits each character whatever the name weighs, and the tag behind it is still read.
        let url = URL(string: "https://public.example.org/page")!
        let page = #"<html><head><meta "# + String(repeating: "a", count: 4_000)
            + #"="x"><meta property="og:title" content="After"><title>Behind</title>"#
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertEqual(metadata.title, "After")
        XCTAssertLessThan(elapsedMilliseconds, 250, "a 4 000 character attribute name took \(elapsedMilliseconds) ms")
    }

    func testThousandsOfTitleOpenersWithoutACloseStayInsideTheBudget() throws {
        // Every opener here is well formed, so each one is handed a body and the search for the
        // </title> that never arrives starts over. The scan remembers one failed search per document
        // instead, so the count of openers stops mattering.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let openers = String(repeating: "<title>", count: 4_600)
        let page = openers + String(repeating: "x", count: PublicLinkHTMLMetadata.metadataWindowBytes - openers.utf8.count)
        XCTAssertEqual(page.utf8.count, PublicLinkHTMLMetadata.metadataWindowBytes)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertNil(metadata.title)
        XCTAssertLessThan(elapsedMilliseconds, 250, "4 600 unclosed title bodies took \(elapsedMilliseconds) ms")
    }

    func testThousandsOfUnclosedMetaOpenersWithOneAngleAtTheWindowEdgeStayInsideTheBudget() throws {
        // One `>` parked past every opener's attribute window: each unclosed `<meta` has to look for the tag
        // end it cannot reach, so an unmemoized search walks the same window once per opener and the count of
        // openers decides the cost. The search is remembered here, so it is paid once per document.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let openers = String(repeating: "<meta ", count: 5_000)
        let page = openers + String(repeating: "x", count: PublicLinkHTMLMetadata.metadataWindowBytes - openers.utf8.count - 1) + ">"
        XCTAssertEqual(page.utf8.count, PublicLinkHTMLMetadata.metadataWindowBytes)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertNil(metadata.title)
        XCTAssertLessThan(elapsedMilliseconds, 250, "5 000 unclosed meta openers took \(elapsedMilliseconds) ms")
    }

    func testThousandsOfRejectedTitleCandidatesStayInsideTheBudget() throws {
        // Every `<title>` is followed by `</titlex>`, which is not a closing tag, so each opener has to rule
        // that candidate out and keep looking. The rejected candidates and the verified answer are remembered
        // apart: a walk that steps past them may not push the raw search record so far forward that the next
        // opener repeats the stretch it left behind.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let page = String(repeating: "<title></titlex>", count: 1_800)
        XCTAssertLessThan(page.utf8.count, PublicLinkHTMLMetadata.metadataWindowBytes)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertNil(metadata.title)
        XCTAssertLessThan(elapsedMilliseconds, 250, "1 800 rejected title candidates took \(elapsedMilliseconds) ms")
    }

    func testThousandsOfRejectedScriptCandidatesStayInsideTheBudget() throws {
        // The same shape inside the script scope, where `</scriptx>` is the candidate that has to be ruled
        // out. Ruling it out is paid once per document, not once per opener.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let page = String(repeating: "<script></scriptx>", count: 1_500)
        XCTAssertLessThan(page.utf8.count, PublicLinkHTMLMetadata.metadataWindowBytes)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertNil(metadata.title)
        XCTAssertLessThan(elapsedMilliseconds, 250, "1 500 rejected script candidates took \(elapsedMilliseconds) ms")
    }

    func testOpenersInFrontOfAValueClosedPastTheAngleStayInsideTheBudget() throws {
        // One attribute value whose closing quote sits past the only `>` in the document, with no `>` after
        // it, and a `<meta ` opener in front of it for every byte of padding. Each opener asks the same
        // question - does a quoted value swallow this tag end - and the answer lies in the same stretch of
        // bytes every time. Looked up fresh, that is one walk over the value per opener: the openers set the
        // cost by themselves, which is the shape the value quote and the tag end are remembered for.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let openers = String(repeating: "<meta ", count: 2_000)
        let filler = String(repeating: "x", count: 8_000)
        // The title is read before the pathological region, which is also where a browser finds it: the tag
        // opened by the first `<meta` swallows everything up to the closing quote, so a title written after it
        // is inside that tag and not a title at all. Pinned in front, the page still has to be paid for by its
        // length and not by its openers, and the metadata it really carries still has to answer.
        let page = "<!doctype html><html><head><title>T</title>" + openers + #"a=""# + filler + ">" + filler + #"""#
            + "</head><body>hi</body></html>"
        XCTAssertLessThan(page.utf8.count, PublicLinkHTMLMetadata.metadataWindowBytes)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertEqual(metadata.title, "T")
        XCTAssertLessThan(elapsedMilliseconds, 250, "2 000 openers in front of one long value took \(elapsedMilliseconds) ms")
    }

    func testOpenersInFrontOfAValueClosedAtTheEndOfTheWindowStayInsideTheBudget() throws {
        // The shape the review names, sized so openers x value is as large as the parse window allows: 2 700
        // `<meta ` openers in front of one value whose closing quote is the last byte of the window, with no
        // `>` behind it. Every opener asks the same question - does a quoted value swallow this tag end - and
        // the answer sits at the far end of the document. Looked up fresh, each lookup re-walks a mid-string
        // range of the document, so the openers price the page by themselves: this page used to take over a
        // second to read, which is what the remembered closing quote is here to stop.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let head = "<!doctype html><html><head><title>T</title>"
        let openers = 2_700
        let filler = (PublicLinkHTMLMetadata.metadataWindowBytes - head.utf8.count - 6 * openers - 4) / 2
        let page = head + String(repeating: "<meta ", count: openers) + #"a=""#
            + String(repeating: "x", count: filler) + ">" + String(repeating: "y", count: filler) + #"""#
        XCTAssertEqual(page.utf8.count, PublicLinkHTMLMetadata.metadataWindowBytes)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertEqual(metadata.title, "T")
        XCTAssertLessThan(elapsedMilliseconds, 250, "\(openers) openers in front of a value closed at the end of the window took \(elapsedMilliseconds) ms")
    }

    func testATagBuiltOutOfShortQuotedValuesIsNotChargedTheWindowPerValue() throws {
        // A tag made of 6 500 four-character quoted values, with its `>` near the parsed window's edge: every
        // value asks where the tag ends and where its own closing quote lies. Those two searches are
        // forward-only memories, so the tag costs its own length rather than its length times the window. It
        // spends more than the 4 096 characters a tag may read reaching its `>`, so it is skipped - and the
        // well-formed tag after it still answers, which pins that the end was found where it really is.
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let head = "<!doctype html><html><head><meta"
        let values = String(repeating: #" a="""#, count: 6_500)
        let trailer = #"""<meta property="og:title" content="Real Title"><title>T</title></head></html>"""#
        let padding = String(repeating: "y", count: PublicLinkHTMLMetadata.metadataWindowBytes
            - head.utf8.count - values.utf8.count - trailer.utf8.count - 1)
        let page = head + values + padding + ">" + trailer
        XCTAssertEqual(page.utf8.count, PublicLinkHTMLMetadata.metadataWindowBytes)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertEqual(metadata.title, "Real Title")
        XCTAssertLessThan(elapsedMilliseconds, 250, "a tag of 6 500 quoted values took \(elapsedMilliseconds) ms")
    }

    func testMetadataPastTheParsedWindowIsNotRead() throws {
        let url = URL(string: "https://synthetic.example.invalid/article")!
        let page = "<html><body>" + String(repeating: "<!-- x -->", count: 20_000) + #"<meta property="og:title" content="Tail">"#
        XCTAssertNil(try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url).title)
    }

    func testMetadataInsideTheParsedWindowIsStillReadThroughFiller() throws {
        // A public host, like the thumbnail cases above: the destination policy is what rejects the .invalid host.
        let url = URL(string: "https://public.example.org/page")!
        let page = #"<html><head>"# + String(repeating: "<!-- x -->", count: 2_400)
            + #"<meta property="og:title" content="Head"><meta name="author" content="Writer"><meta property="og:image" content="/cover.png">"#
            + #"</head><body>text</body></html>"#
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        XCTAssertEqual(metadata.title, "Head")
        XCTAssertEqual(metadata.author, "Writer")
        XCTAssertEqual(metadata.thumbnailURL?.path, "/cover.png")
    }

    func testTagNameCaseDoesNotChangeWhatIsRead() throws {
        // Tag names carry no case guarantee in the field, so an all-caps document has to yield what the
        // same document with lower-case tag names yields, values included staying exactly as written.
        let url = URL(string: "https://public.example.org/page")!
        let shouted = #"<html><head><META PROPERTY="og:title" CONTENT="Shout"><TITLE>Fallback</TITLE><meta NAME=AUTHOR CONTENT=Writer>"#
        let whispered = #"<html><head><meta property="og:title" content="Shout"><title>Fallback</title><meta name=author content=Writer>"#
        let loud = try PublicLinkHTMLMetadata(data: Data(shouted.utf8), url: url)
        XCTAssertEqual(loud.title, "Shout")
        XCTAssertEqual(loud.author, "Writer")
        XCTAssertEqual(loud, try PublicLinkHTMLMetadata(data: Data(whispered.utf8), url: url))
    }

    func testUnclosedScriptOrCommentLeavesTheRestOfTheDocumentReadable() throws {
        // An opening token with no closing token opens no body, so the document after it is still read.
        // A script or style that does close hides what it contains, which the case above already pins.
        let url = URL(string: "https://public.example.org/page")!
        let afterScript = try PublicLinkHTMLMetadata(data: Data("<html><!-- never closed<script><meta name=author content='In'></script><meta property='og:title' content='Out'>".utf8), url: url)
        XCTAssertEqual(afterScript.title, "Out")
        XCTAssertNil(afterScript.author, "the script body hides its own metadata")
        let openScript = try PublicLinkHTMLMetadata(data: Data("<html><script>var a = 1;<meta property='og:title' content='StillRead'>".utf8), url: url)
        XCTAssertEqual(openScript.title, "StillRead")
    }

    func testAClosingTagThatIsNotOneNeitherEndsTheRegionNorDropsTheTitle() throws {
        // \</titlex\> and \</scriptx\> start like a closing tag but are not one. Stopping the title
        // search at such a candidate loses the title the document really declares, and ending a script
        // region at one publishes the script's own text as the page title, so a candidate counts only
        // when the tag it names actually ends there.
        let url = URL(string: "https://public.example.org/page")!
        let title = try PublicLinkHTMLMetadata(data: Data("<html><head><title>Good</titlex> Rest</title>".utf8), url: url)
        XCTAssertEqual(title.title, "Good Rest")
        let script = try PublicLinkHTMLMetadata(data: Data(#"<html><script>"<title>fake";</scriptx>data <title>Real</title></script>"#.utf8), url: url)
        XCTAssertNil(script.title, "the script region still covers everything up to the real closing tag")
        let spaced = try PublicLinkHTMLMetadata(data: Data("<html><head><title>Ok</title >".utf8), url: url)
        XCTAssertEqual(spaced.title, "Ok", "white space before the closing angle bracket is still a close")
    }

    func testOnlyTheFirst256MetaTagsAreConsidered() throws {
        let url = URL(string: "https://public.example.org/page")!
        let filler = (0..<256).map { #"<meta name="k"# + String($0) + #"" content="v">"# }.joined()
        let page = filler + #"<meta property="og:title" content="Late"><title>Fallback</title>"#
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        XCTAssertEqual(metadata.title, "Fallback")
    }

    func testAMetaTagOpenedInsideAnotherTagsValueCannotAnswerAField() throws {
        // A `<meta>` typed inside an attribute value is that value's text, not the start of a tag. Ending a
        // tag at the first `>` inside a quoted value hands the rest of the value to the attribute parser as
        // the tag's own attributes, so such a `<meta>` becomes the next tag and the page can name its own
        // `og:title` or `og:image` from inside a description. Windows ends a tag the same way in
        // windows/lib/network.cjs: the same page must not answer differently on the two platforms.
        let url = URL(string: "https://public.example.org/page")!
        let quotingATitle = #"<html><head><meta name="description" content="see <meta property='og:title' content='Injected'> for details"><title>Gerçek Başlık</title></head></html>"#
        XCTAssertEqual(try PublicLinkHTMLMetadata(data: Data(quotingATitle.utf8), url: url).title, "Gerçek Başlık",
                       "a meta tag inside an attribute value must not answer og:title")
        let quotingAnImage = #"<html><head><meta name="description" content="<meta property='og:image' content='/injected.png'>"><meta property="og:image" content="/real.png"><title>T</title></head></html>"#
        XCTAssertEqual(try PublicLinkHTMLMetadata(data: Data(quotingAnImage.utf8), url: url).thumbnailURL?.path, "/real.png",
                       "an injected og:image must lose to the one the page declares")
    }

    func testAMetaTagWhoseValueQuotesMarkupPastTheBudgetCannotForgeATitle() throws {
        // The 4 096-character budget says how much of a tag may be read, not where the next tag begins. The
        // search has to resume after the tag it located, or a page buries an `og:title` inside a description
        // long enough for this parser to skip it, and the buried one answers instead of the `<title>`.
        let url = URL(string: "https://public.example.org/page")!
        let page = #"<html><head><meta name="description" content="<meta property='og:title' content='Fake'>"#
            + String(repeating: "x", count: 5_000)
            + #" end"><title>Gerçek Başlık</title></head></html>"#
        XCTAssertEqual(try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url).title, "Gerçek Başlık")
    }

    func testAnApostropheThatDoesNotFollowAnEqualsSignDoesNotMoveTheEndOfATag() throws {
        // `name=it's` is an unquoted value with an apostrophe in it, not a value that opens and never closes.
        // Reading it as one drags the end of the tag into the text after it and swallows the `og:title` and
        // `og:image` the page declares. Only a quote that follows `=` opens a value on Windows either.
        let url = URL(string: "https://public.example.org/page")!
        let page = "<html><head><meta name=it's content=\"x\"><meta property=\"og:title\" content=\"Later\"><meta property=\"og:image\" content=\"https://public.example.org/a.png\"><title>It's fine</title></head></html>"
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        XCTAssertEqual(metadata.title, "Later", "a value that is not quoted must not swallow the og:title after it")
        XCTAssertEqual(metadata.thumbnailURL?.path, "/a.png")
    }

    func testThousandsOfClosedMetaTagsStayInsideTheBudget() throws {
        // The budget a tag may spend reaching its `>` has to be measured against that tag's own length. Asking
        // for the position that many characters ahead instead prices every tag at the whole budget, so short
        // tags cost tags x budget: 32 KiB of closed `<meta>` took 100.9 ms that way, 2.3 ms before the scan
        // existed, and 5.2 ms measured with the walker that replaced it.
        let url = URL(string: "https://public.example.org/page")!
        let page = String(repeating: "<meta>", count: 5_461)
        XCTAssertEqual(page.utf8.count, PublicLinkHTMLMetadata.metadataWindowBytes - 2)
        let started = DispatchTime.now().uptimeNanoseconds
        let metadata = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertNil(metadata.title)
        XCTAssertLessThan(elapsedMilliseconds, 250, "5 461 closed meta tags took \(elapsedMilliseconds) ms")
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
