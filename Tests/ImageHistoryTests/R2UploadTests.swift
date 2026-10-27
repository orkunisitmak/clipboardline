import AppKit
import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class R2UploadTests: HistoryTestCase {
    private final class RecordingTransport: R2HTTPTransport, @unchecked Sendable {
        struct Call: Sendable {
            let url: URL
            let method: String
            let headers: [String: String]
            let body: Data?
        }
        private let lock = NSLock()
        private var recorded = [Call]()
        var status = 200

        var calls: [Call] {
            lock.withLock { recorded }
        }

        func send(url: URL, method: String, headers: [String: String], body: Data?) async throws -> (status: Int, body: Data) {
            let code = lock.withLock { () -> Int in
                recorded.append(Call(url: url, method: method, headers: headers, body: body))
                return status
            }
            return (code, Data())
        }
    }

    private final class TokenSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var counter = 0
        func next() -> String {
            lock.withLock {
                counter += 1
                return String(format: "tok%013d", counter)
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    func testSigV4MatchesCrossPlatformReferenceVector() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let fixedDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12, minute: 0, second: 0)))
        let body = Data("hello r2\n".utf8)
        let payloadHash = R2SigV4.sha256Hex(body)
        XCTAssertEqual(payloadHash, ["a0455c221b23d13d", "f3054c5ab80a86ed", "34443655930de1fb", "35dd96f9c13569cf"].joined())

        let signed = try R2SigV4.sign(
            method: "PUT",
            endpoint: try XCTUnwrap(URL(string: "https://test-account.r2.cloudflarestorage.com")),
            pathSegments: ["test-bucket", "clips", "sample0123456789.txt"],
            extraHeaders: ["Content-Type": "text/plain; charset=utf-8", "Content-Length": "\(body.count)"],
            payloadHash: payloadHash,
            accessKeyId: "test-access-key",
            secretAccessKey: String(repeating: "s", count: 24),
            date: fixedDate
        )

        XCTAssertEqual(signed.url.absoluteString, "https://test-account.r2.cloudflarestorage.com/test-bucket/clips/sample0123456789.txt")
        let expectedRequestDigest = ["1ec28a5bd48cdd64", "277f9dfa59a6e9c7", "a1ca2378a7b32948", "8eda15c920be8b44"].joined()
        XCTAssertEqual(signed.stringToSign, "AWS4-HMAC-SHA256\n20261027T120000Z\n20261027/auto/s3/aws4_request\n\(expectedRequestDigest)")
        let expectedSig = ["6b74abc012176dcf", "41459c106469d48d", "d1ca9fb42c11fcf4", "409c90097dcd927c"].joined()
        XCTAssertEqual(
            signed.headers["Authorization"],
            "AWS4-HMAC-SHA256 Credential=test-access-key/20261027/auto/s3/aws4_request, SignedHeaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date, Signature=\(expectedSig)"
        )
    }

    func testValidatorNormalizesEndpointsAndRejectsUnsafeInputs() throws {
        let valid = try R2Validator.validate(R2Configuration(
            accountId: "test-account",
            accessKeyId: "test-access-key",
            bucket: "my-clips",
            publicBaseUrl: "https://cdn.example.com/public/",
            keyPrefix: "/2026/oct/"
        ))
        XCTAssertEqual(valid.endpoint.absoluteString, "https://test-account.r2.cloudflarestorage.com")
        XCTAssertEqual(valid.bucket, "my-clips")
        XCTAssertEqual(valid.publicBaseUrl, "https://cdn.example.com/public")
        XCTAssertEqual(valid.keyPrefix, "2026/oct")
        XCTAssertEqual(R2Validator.makeObjectKey(prefix: valid.keyPrefix, token: "tok123", fileExtension: ".PNG"), "2026/oct/tok123.png")

        let customEndpoint = try R2Validator.validate(R2Configuration(
            accountId: "https://s3.example.com/",
            accessKeyId: "test-access-key",
            bucket: "my-clips",
            publicBaseUrl: "https://cdn.example.com",
            keyPrefix: ""
        ))
        XCTAssertEqual(customEndpoint.endpoint.absoluteString, "https://s3.example.com")

        let userInfoEndpoint = "https://" + "u" + ":" + "p@s3.example.com"
        for badEndpoint in ["http://s3.example.com", "https://localhost", "https://127.0.0.1", "https://10.0.0.5", "https://192.168.1.1", userInfoEndpoint] {
            XCTAssertThrowsError(try R2Validator.validate(R2Configuration(
                accountId: badEndpoint, accessKeyId: "test-access-key", bucket: "my-clips", publicBaseUrl: "https://cdn.example.com", keyPrefix: ""
            )))
        }
        for badBucket in ["ab", "my_clips", "bad..bucket", "-clips", "192.168.1.1"] {
            XCTAssertThrowsError(try R2Validator.validate(R2Configuration(
                accountId: "test-account", accessKeyId: "test-access-key", bucket: badBucket, publicBaseUrl: "https://cdn.example.com", keyPrefix: ""
            )))
        }
        XCTAssertThrowsError(try R2Validator.validate(R2Configuration(
            accountId: "test-account", accessKeyId: "test-access-key", bucket: "my-clips", publicBaseUrl: "http://cdn.example.com", keyPrefix: ""
        )))
        XCTAssertThrowsError(try R2Validator.validate(R2Configuration(
            accountId: "test-account", accessKeyId: "test-access-key", bucket: "my-clips", publicBaseUrl: "https://cdn.example.com", keyPrefix: "clips/../secret"
        )))
    }

    func testSecretNeverTouchesUserDefaults() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let secretValue = String(repeating: "k", count: 24)
        let secrets = InMemoryR2SecretStore()
        let coordinator = R2UploadCoordinator(store: nil, defaults: f.defaults, secrets: secrets, transport: RecordingTransport(), writeLink: { _ in true })
        let before = f.defaults.persistentDomain(forName: f.suite) ?? [:]
        _ = coordinator.configuration
        XCTAssertEqual((f.defaults.persistentDomain(forName: f.suite) ?? [:]).count, before.count)

        try coordinator.saveSecret(secretValue)
        XCTAssertTrue(coordinator.hasSavedSecret)
        let domainString = String(describing: f.defaults.persistentDomain(forName: f.suite) ?? [:])
        XCTAssertFalse(domainString.contains(secretValue))

        try coordinator.clearSecret()
        XCTAssertFalse(coordinator.hasSavedSecret)
    }

    func testCoordinatorUploadsCachesReuploadsAndInvalidatesOnContentEdits() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let secrets = InMemoryR2SecretStore(initial: String(repeating: "s", count: 24))
        let transport = RecordingTransport()
        var copiedLinks = [String]()
        let tokens = TokenSequence()
        let coordinator = R2UploadCoordinator(
            store: store,
            defaults: f.defaults,
            secrets: secrets,
            transport: transport,
            writeLink: { copiedLinks.append($0.absoluteString); return true },
            now: { Date(timeIntervalSince1970: 1_793_102_400) },
            makeToken: { tokens.next() }
        )
        coordinator.saveConfiguration(R2Configuration(
            accountId: "test-account",
            accessKeyId: "test-access-key",
            bucket: "test-bucket",
            publicBaseUrl: "https://cdn.example.com",
            keyPrefix: "clips"
        ))

        let textItem = try XCTUnwrap(store.captureText("Shottr style R2 upload"))
        var firstOutcome: R2UploadCoordinator.Outcome?
        coordinator.upload(textItem.id) { firstOutcome = $0 }
        waitUntil { firstOutcome != nil }
        XCTAssertEqual(firstOutcome, .uploaded(try XCTUnwrap(URL(string: "https://cdn.example.com/clips/tok0000000000001.txt"))))
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.calls[0].method, "PUT")
        XCTAssertEqual(transport.calls[0].headers["content-type"], "text/plain; charset=utf-8")
        XCTAssertEqual(transport.calls[0].body, Data("Shottr style R2 upload".utf8))
        XCTAssertEqual(try store.item(textItem.id)?.uploadedURL, "https://cdn.example.com/clips/tok0000000000001.txt")
        XCTAssertEqual(copiedLinks, ["https://cdn.example.com/clips/tok0000000000001.txt"])

        // Second upload without forceReupload copies cached link with zero network requests.
        var cachedOutcome: R2UploadCoordinator.Outcome?
        coordinator.upload(textItem.id, forceReupload: false) { cachedOutcome = $0 }
        XCTAssertEqual(cachedOutcome, .copiedExisting(try XCTUnwrap(URL(string: "https://cdn.example.com/clips/tok0000000000001.txt"))))
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(copiedLinks.count, 2)

        // Explicit re-upload issues a fresh PUT and updates uploadedURL.
        var reuploadOutcome: R2UploadCoordinator.Outcome?
        coordinator.upload(textItem.id, forceReupload: true) { reuploadOutcome = $0 }
        waitUntil { reuploadOutcome != nil }
        XCTAssertEqual(reuploadOutcome, .uploaded(try XCTUnwrap(URL(string: "https://cdn.example.com/clips/tok0000000000002.txt"))))
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(try store.item(textItem.id)?.uploadedURL, "https://cdn.example.com/clips/tok0000000000002.txt")

        // Renaming/note metadata preserves uploadedURL, whereas mutating text invalidates it.
        try store.update(textItem.id) { $0.title = "Friendly title"; $0.note = "Context note" }
        XCTAssertEqual(try store.item(textItem.id)?.uploadedURL, "https://cdn.example.com/clips/tok0000000000002.txt")
        try store.update(textItem.id) { $0.text = "Edited body invalidates cached URL" }
        XCTAssertNil(try store.item(textItem.id)?.uploadedURL)

        // Uploading an image and saving markup invalidates uploadedURL.
        let imageItem = try store.captureImage(f.image(name: "Capture.png"))
        var imageOutcome: R2UploadCoordinator.Outcome?
        coordinator.upload(imageItem.id) { imageOutcome = $0 }
        waitUntil { imageOutcome != nil }
        XCTAssertEqual(try store.item(imageItem.id)?.uploadedURL, "https://cdn.example.com/clips/tok0000000000003.png")
        let markup = ImageMarkupDocument(elements: [
            ImageMarkupElement(tool: .rectangle, points: [MarkupPoint(x: 0.1, y: 0.1), MarkupPoint(x: 0.8, y: 0.8)],
                               color: .red, lineWidth: 0.025, fill: false, text: nil, fontSize: 0.2)
        ])
        try store.saveImageMarkup(imageItem.id, document: markup)
        XCTAssertNil(try store.item(imageItem.id)?.uploadedURL)
    }

    func testUnconfiguredAndMultiSelectionUploadGuards() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let first = try store.captureImage(f.image(name: "One.png"))
        f.date += 1
        _ = try store.captureImage(f.image(name: "Two.png"))

        let unconfigured = R2UploadCoordinator(store: store, defaults: f.defaults, secrets: InMemoryR2SecretStore(), transport: RecordingTransport(), writeLink: { _ in true })
        var outcome: R2UploadCoordinator.Outcome?
        unconfigured.upload(first.id) { outcome = $0 }
        XCTAssertEqual(outcome, .notConfigured)

        let line = Line(defaults: f.defaults, inbox: f.inbox, now: { f.date }, breeze: false, copyImage: { _ in }, copyText: { _ in }, library: store)
        var requested = [(UUID, Bool)]()
        line.onUploadRequested = { requested.append(($0, $1)) }
        line.revealed = true
        let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { _ in }, onClose: {})

        let shiftRight = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        _ = keyboard.handle(shiftRight)
        XCTAssertEqual(line.selectedIDs.count, 2)

        let uKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "u", charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32))
        _ = keyboard.handle(uKey)
        XCTAssertTrue(requested.isEmpty)

        // Returning to a single selection allows U to request upload.
        line.select(first.id)
        _ = keyboard.handle(uKey)
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.0, first.id)
        XCTAssertEqual(requested.first?.1, false)
    }
}
