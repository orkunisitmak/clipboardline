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

    func testNewSnapshotDoesNotTreatInboxManagedValuesAsUserSettings() {
        let folder = URL(fileURLWithPath: "/tmp/clipboardline-inbox")
        let current: [String: Any] = [
            "location": folder.path,
            "locationScreenshot": folder.path,
            "locationRecording": folder.path,
            "thumbnail": false,
            "target": "file",
            "targetScreenshot": "file",
            "targetRecording": "file"
        ]

        XCTAssertTrue(InboxSettings.initialSnapshot(current: current, folder: folder).isEmpty,
                      "An Inbox-created location must not become the previous destination after reinstall")
    }

    func testNewSnapshotKeepsOnlyIndependentUserChanges() {
        let folder = URL(fileURLWithPath: "/tmp/clipboardline-inbox")
        let current: [String: Any] = [
            "location": folder.path,
            "locationScreenshot": "/Users/example/Desktop",
            "locationRecording": folder.path,
            "thumbnail": true,
            "target": "file",
            "targetScreenshot": "clipboard",
            "targetRecording": "file"
        ]

        let saved = InboxSettings.initialSnapshot(current: current, folder: folder)
        XCTAssertEqual(saved["locationScreenshot"] as? String, "/Users/example/Desktop")
        XCTAssertEqual(saved["thumbnail"] as? Bool, true)
        XCTAssertEqual(saved["targetScreenshot"] as? String, "clipboard")
        XCTAssertEqual(saved.count, 3)
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
