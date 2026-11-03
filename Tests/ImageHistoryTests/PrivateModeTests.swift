import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// Private mode never leaves macOS pointing at the app's screenshot folder
/// while nothing is allowed to pick the screenshots up. These tests drive the
/// real Inbox apply/restore logic through its preference seam, so the user's
/// own macOS screenshot settings are never read or written.
@MainActor final class PrivateModeTests: HistoryTestCase {
    /// The screenshot preferences as macOS would hold them.
    private final class FakeScreenshotPreferences: Inbox.Preferences {
        var values: [String: Any]
        init(values: [String: Any]) { self.values = values }
        func value(_ key: CFString) -> Any? { values[key as String] }
        func set(_ key: CFString, _ value: Any?) {
            if let value { values[key as String] = value } else { values.removeValue(forKey: key as String) }
        }
    }

    private struct Environment {
        let defaults: UserDefaults
        let preferences: FakeScreenshotPreferences
        let userLocation: String
    }

    private func withInbox(_ body: (Environment) throws -> Void) throws {
        let suite = "private-mode-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let userLocation = "/private/tmp/screen-recordings-fixture"
        let preferences = FakeScreenshotPreferences(values: [
            "location": userLocation,
            "location-screenshot": userLocation,
            "show-thumbnail": true,
            "target": "clipboard"
        ])
        let previousDefaults = Inbox.defaults, previousPreferences = Inbox.preferences
        let previousPauseDefaults = CapturePause.defaults
        Inbox.defaults = defaults
        Inbox.preferences = preferences
        CapturePause.defaults = defaults
        defer {
            Inbox.defaults = previousDefaults
            Inbox.preferences = previousPreferences
            CapturePause.defaults = previousPauseDefaults
            defaults.removePersistentDomain(forName: suite)
        }
        try body(Environment(defaults: defaults, preferences: preferences, userLocation: userLocation))
    }

    /// A relaunch while private mode is on must not take the screenshots over:
    /// they would land in the app's folder with every watcher skipping them.
    func testInboxIsNotAppliedAtLaunchWhilePrivateModeIsOn() throws {
        try withInbox { environment in
            environment.defaults.set(true, forKey: "inboxEnabled")
            environment.defaults.set(true, forKey: "capturePaused")

            Inbox.reconcileIfEnabled(paused: CapturePause.isPaused)

            XCTAssertEqual(environment.preferences.value("location" as CFString) as? String, environment.userLocation)
            XCTAssertEqual(environment.preferences.value("show-thumbnail" as CFString) as? Bool, true)
            XCTAssertFalse(Inbox.isApplied)
        }
    }

    /// A build with Inbox off shares the folder but not the saved settings, so
    /// launch must leave a destination another build applied alone instead of
    /// restoring from its own empty ones.
    func testInboxOffLeavesAnotherBuildsAppliedDestinationAlone() throws {
        try withInbox { environment in
            environment.defaults.set(false, forKey: "inboxEnabled")
            environment.preferences.set("location" as CFString, Inbox.folder.path)
            environment.preferences.set("show-thumbnail" as CFString, false)

            Inbox.reconcileIfEnabled(paused: false)
            Inbox.reconcileIfEnabled(paused: true)

            XCTAssertTrue(Inbox.isApplied)
            XCTAssertEqual(environment.preferences.value("location" as CFString) as? String, Inbox.folder.path)
            XCTAssertEqual(environment.preferences.value("show-thumbnail" as CFString) as? Bool, false)
        }
    }

    /// Turning the choice on while private mode is on waits for the resume.
    func testTurningInboxOnWhilePausedKeepsTheUsersOwnDestination() throws {
        try withInbox { environment in
            environment.defaults.set(true, forKey: "inboxEnabled")

            Inbox.reconcile(enabled: true, paused: true)

            XCTAssertEqual(environment.preferences.value("location" as CFString) as? String, environment.userLocation)
            XCTAssertFalse(Inbox.isApplied)
        }
    }

    /// Resuming applies Inbox, and pausing again hands the user's destination back.
    func testResumeAppliesInboxAndPauseRestoresTheUsersOwnSettings() throws {
        try withInbox { environment in
            Inbox.reconcile(enabled: true, paused: true)
            XCTAssertFalse(Inbox.isApplied)

            Inbox.reconcile(enabled: true, paused: false)
            XCTAssertTrue(Inbox.isApplied)
            XCTAssertEqual(environment.preferences.value("location" as CFString) as? String, Inbox.folder.path)
            XCTAssertEqual(environment.preferences.value("show-thumbnail" as CFString) as? Bool, false)
            XCTAssertEqual(environment.preferences.value("target" as CFString) as? String, "file")

            Inbox.reconcile(enabled: true, paused: true)
            XCTAssertFalse(Inbox.isApplied)
            XCTAssertEqual(environment.preferences.value("location" as CFString) as? String, environment.userLocation)
            XCTAssertEqual(environment.preferences.value("show-thumbnail" as CFString) as? Bool, true)
            XCTAssertEqual(environment.preferences.value("target" as CFString) as? String, "clipboard")
        }
    }

    /// Turning Inbox off while private mode is on still restores what was
    /// applied before the pause, so macOS never keeps pointing at our folder.
    func testTurningInboxOffWhilePausedRestoresTheUsersOwnSettings() throws {
        try withInbox { environment in
            Inbox.reconcile(enabled: true, paused: false)
            XCTAssertTrue(Inbox.isApplied)

            Inbox.reconcile(enabled: false, paused: true)

            XCTAssertFalse(Inbox.isApplied)
            XCTAssertEqual(environment.preferences.value("location" as CFString) as? String, environment.userLocation)
        }
    }
}
