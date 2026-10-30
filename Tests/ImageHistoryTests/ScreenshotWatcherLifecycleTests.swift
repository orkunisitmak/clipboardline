import Foundation
import XCTest
@testable import Tendedero

@MainActor
final class ScreenshotWatcherLifecycleTests: XCTestCase {
    func testWatcherRebindsWhenItsFolderIsReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-lifecycle-\(UUID())")
        let folder = root.appendingPathComponent("Captures", isDirectory: true)
        let moved = root.appendingPathComponent("Captures moved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = try SyntheticFixture(folderRoot: root)
        defer { fixture.cleanup() }
        let image = try fixture.image(owned: false)
        let imageData = try Data(contentsOf: image)
        let marker = folder.appendingPathComponent("replacement-marker.png")
        let nextCapture = folder.appendingPathComponent("next-capture.png")
        let baselineScanned = expectation(description: "initial watcher scan completed")
        let markerCaptured = expectation(description: "replacement directory scan found its image")
        let nextCaptureCaptured = expectation(description: "watcher reported the next image")
        var baselineReady = false

        let watcher = ScreenshotWatcher(folder: folder, anyImage: true, onNew: { url in
            if url.standardizedFileURL.path == marker.standardizedFileURL.path { markerCaptured.fulfill() }
            if url.standardizedFileURL.path == nextCapture.standardizedFileURL.path { nextCaptureCaptured.fulfill() }
        }, onChange: {
            if !baselineReady {
                baselineReady = true
                baselineScanned.fulfill()
            }
        })
        defer { watcher.stop() }
        watcher.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            try? Data("warm up".utf8).write(to: folder.appendingPathComponent("warmup.txt"))
        }
        wait(for: [baselineScanned], timeout: 3)

        let originalAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        let originalDevice = try XCTUnwrap(originalAttributes[.systemNumber] as? NSNumber)
        let originalInode = try XCTUnwrap(originalAttributes[.systemFileNumber] as? NSNumber)
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let replacementAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        let replacementDevice = try XCTUnwrap(replacementAttributes[.systemNumber] as? NSNumber)
        let replacementInode = try XCTUnwrap(replacementAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(originalDevice, replacementDevice)
        XCTAssertNotEqual(originalInode, replacementInode, "the watched path must point at a replacement directory inode")
        try imageData.write(to: marker)
        wait(for: [markerCaptured], timeout: 3)

        try imageData.write(to: nextCapture)
        wait(for: [nextCaptureCaptured], timeout: 2)
    }
}
