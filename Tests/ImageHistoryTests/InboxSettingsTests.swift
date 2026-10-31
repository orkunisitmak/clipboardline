import Foundation
import XCTest
@testable import Tendedero

final class InboxSettingsTests: XCTestCase {
    func testScreenshotSpecificLocationOverridesLegacyLocation() {
        let folder = URL(fileURLWithPath: "/tmp/clipboardline-inbox")
        let current: [String: Any] = [
            "location": folder.path,
            "locationScreenshot": "/Users/example/Desktop"
        ]

        XCTAssertFalse(InboxSettings.isApplied(current: current, folder: folder))
    }

    func testRestoreLeavesSettingsChangedInOptions() {
        let folder = URL(fileURLWithPath: "/tmp/clipboardline-inbox")
        let current: [String: Any] = [
            "location": folder.path,
            "locationScreenshot": "/Users/example/Desktop",
            "locationRecording": folder.path,
            "thumbnail": false,
            "target": "file",
            "targetScreenshot": "clipboard",
            "targetRecording": "file"
        ]

        XCTAssertEqual(
            InboxSettings.restorableKeys(current: current, folder: folder),
            ["location", "locationRecording", "thumbnail", "target", "targetRecording"]
        )
    }

    func testReapplyingInboxUpdatesOnlyUserChangedSavedSettings() {
        let folder = URL(fileURLWithPath: "/tmp/clipboardline-inbox")
        let current: [String: Any] = [
            "location": folder.path,
            "locationScreenshot": "/Users/example/Desktop",
            "locationRecording": folder.path,
            "thumbnail": false,
            "target": "file",
            "targetScreenshot": "file",
            "targetRecording": "file"
        ]

        XCTAssertEqual(
            InboxSettings.userChangedKeys(current: current, folder: folder),
            ["locationScreenshot"]
        )
    }
}
