import AppKit
import AVFoundation
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

@MainActor final class UpstreamMergeTests: HistoryTestCase {
    func testSideRemovalUsesVisibleNewestLeftOrderAndConfirmationSnapshot() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let line = f.line()
        for _ in 0..<5 { line.hang(try f.image(), quietly: true) }
        let order = line.displayItems
        XCTAssertEqual(line.neighbours(of: order[2].id, toTheLeft: true).map(\.id), Array(order.prefix(2)).map(\.id))
        XCTAssertEqual(line.neighbours(of: order[2].id, toTheLeft: false).map(\.id), Array(order.suffix(2)).map(\.id))
        line.takeDown(order[2].id, toTheLeft: true)
        // the two photos on the left come off the shelf at once
        XCTAssertEqual(line.items.filter { !$0.falling }.map(\.id).sorted { $0.uuidString < $1.uuidString }, order.suffix(3).map(\.id).sorted { $0.uuidString < $1.uuidString })
        line.hang(try f.image(), quietly: true)
        XCTAssertEqual(line.items.filter { !$0.falling }.count, 4)
        _ = try line.togglePin(order[3].id); _ = try line.togglePin(order[4].id)
        line.setFavoritesOnly(true)
        XCTAssertEqual(line.neighbours(of: order[3].id, toTheLeft: false).map(\.id), [order[4].id])
    }
    func testSizePersistsWithoutLosingHistoryOrThumbnailBounds() throws {
        let f = try SyntheticFixture(); defer { f.cleanup(); Layout.size = .medium }
        let line = f.line()
        for _ in 0..<110 { line.hang(try f.image(), quietly: true) }
        let ids = line.items.map(\.id)
        XCTAssertEqual(line.retentionDays, 30)
        for size in Layout.Size.allCases {
            line.setPresentation(.both, requestFocus: false); line.setSize(size)
            XCTAssertEqual(line.panelHeight, Layout.panelHeight * 2)
            XCTAssertEqual(line.items.map(\.id), ids)
            XCTAssertTrue(line.items.filter { $0.thumb != nil }.count <= line.visibleRange.count)
        }
        XCTAssertEqual(f.line().size, .large)
        XCTAssertEqual(f.line().items.count, 110)
    }
    func testRecordingFileTransfersPreserveMixedItemsWithoutReadingMovieBytes() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let image = try f.image()
        let movie = f.folder.appendingPathComponent("Synthetic.mov")
        try Data([0, 1, 2]).write(to: movie) // file transfer must not decode video
        let board = NSPasteboard(name: .init("merge-test-\(UUID())")); defer { board.releaseGlobally() }
        let payload = try ClipboardTransfer.imageItems([image, movie, image])
        XCTAssertTrue(ClipboardTransfer.write(payload, to: board))
        XCTAssertEqual(board.pasteboardItems?.count, 3)
        XCTAssertEqual(board.pasteboardItems?[1].string(forType: .fileURL), movie.absoluteString)
        XCTAssertNil(board.pasteboardItems?[1].data(forType: .png))
        XCTAssertEqual(board.pasteboardItems?[0].data(forType: .png), try Data(contentsOf: image))
        let symlink = f.folder.appendingPathComponent("unsafe.mov")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: movie)
        var refused = false
        do { _ = try ClipboardTransfer.imageItems([symlink]) } catch { refused = true }
        XCTAssertTrue(refused)
        XCTAssertEqual(board.pasteboardItems?.count, 3)
    }
    func testFolderCandidatesRejectSymlinksAndRestrictRecordings() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let image = try f.image()
        let watcher = ScreenshotWatcher(folder: f.inbox, anyImage: true, onNew: { _ in }, onChange: {})
        XCTAssertTrue(watcher.isCandidate(image))
        let symlink = f.inbox.appendingPathComponent("unsafe.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: image)
        XCTAssertFalse(watcher.isCandidate(symlink))
        let movie = f.inbox.appendingPathComponent("Synthetic.mp4"); try Data([0]).write(to: movie)
        XCTAssertFalse(watcher.isCandidate(movie)) // arbitrary watched folders only import images
        XCTAssertTrue(isRecordingFile(movie))
        XCTAssertFalse(isRecordingFile(image))
    }
    func testGeneratedRecordingThumbnailAndPinnedExpiryKeepOriginal() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let movie = f.folder.appendingPathComponent("Synthetic.mov")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            memset(address, 120, CVPixelBufferGetBytesPerRow(pixels) * 16)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(writer.status, .completed)
        XCTAssertTrue(makeThumbnail(movie) != nil)
        let line = f.line()
        let ownID = try XCTUnwrap(line.hang(movie, quietly: true))
        XCTAssertTrue(line.items[0].isRecording)
        XCTAssertTrue(try line.togglePin(ownID))
        XCTAssertTrue(line.items[0].url != movie)
        XCTAssertTrue(line.historyFiles.isAppCopy(line.items[0].url))
        f.date += 31 * 86400; line.prune()
        XCTAssertEqual(line.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
    }
    func testToggleShortcutValidationAndUpstreamLinkAreForkSafe() {
        XCTAssertTrue(Shortcut.standard.isUsable)
        XCTAssertFalse(Shortcut(keyCode: -1, modifiers: .command, key: "a").isUsable)
        XCTAssertFalse(Shortcut(keyCode: 200, modifiers: .command, key: "a").isUsable)
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: .shift, key: "a").isUsable)
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: [.command, .capsLock], key: "a").isUsable)
        XCTAssertEqual(AppDelegate.updatesURL.absoluteString, "https://github.com/alejandrobujan/tendedero/releases")
    }
}
