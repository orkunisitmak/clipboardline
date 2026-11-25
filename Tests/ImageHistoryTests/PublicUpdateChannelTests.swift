import Foundation
#if canImport(Sparkle)
import Combine
#endif
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

final class PublicUpdateChannelTests: HistoryTestCase {
    private var info: [String: Any] {
        ["CFBundleIdentifier": "local.clipboardline.review",
         "ClipboardLinePublicUpdateRepository": "orkunisitmak/clipboardline-desktop",
         "SUFeedURL": "https://github.com/orkunisitmak/clipboardline-desktop/releases/latest/download/appcast.xml",
         "SUPublicEDKey": "ASY6h/Y7xsg4fUmA8TleW6XhbhOtn5M6ql4eqq8o3sE=",
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
         "SUSignedFeedFailureExpirationInterval": 0,
         "SUAllowsAutomaticUpdates": false, "SUAutomaticallyUpdate": false,
         "SUEnableSystemProfiling": false]
    }

    func testOnlyBundledAnonymousChannelIsAccepted() {
        XCTAssertEqual(PublicUpdateChannel(info: info)?.feedURL.absoluteString, PublicUpdateChannel.feed)
        for (key, invalid) in [
            ("CFBundleIdentifier", "another.app"),
            ("ClipboardLinePublicUpdateRepository", "orkunisitmak/clipboardline"),
            ("SUFeedURL", "https://github.com/orkunisitmak/clipboardline/releases/latest/download/appcast.xml"),
            ("SUFeedURL", "http://127.0.0.1/appcast.xml"),
            ("SUFeedURL", PublicUpdateChannel.feed + "?token=private"),
            ("SUPublicEDKey", Data(repeating: 1, count: 32).base64EncodedString())
        ] {
            var candidate = info
            candidate[key] = invalid
            XCTAssertNil(PublicUpdateChannel(info: candidate), key)
        }
    }

    func testLegacySignedBundleKeepsItsExactFeedWithoutAcceptingMixedChannels() {
        var legacy = info
        legacy["ClipboardLinePublicUpdateRepository"] = PublicUpdateChannel.legacyRepository
        legacy["SUFeedURL"] = PublicUpdateChannel.legacyFeed
        XCTAssertEqual(PublicUpdateChannel(info: legacy)?.feedURL.absoluteString, PublicUpdateChannel.legacyFeed)
        legacy["ClipboardLinePublicUpdateRepository"] = PublicUpdateChannel.repository
        XCTAssertNil(PublicUpdateChannel(info: legacy))
        legacy["SUFeedURL"] = PublicUpdateChannel.feed
        legacy["ClipboardLinePublicUpdateRepository"] = PublicUpdateChannel.legacyRepository
        XCTAssertNil(PublicUpdateChannel(info: legacy))
    }

    func testMissingOrRelaxedVerificationAndAutomaticInstallationAreRejected() {
        for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUSignedFeedFailureExpirationInterval",
                    "SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"] {
            var candidate = info
            candidate.removeValue(forKey: key)
            XCTAssertNil(PublicUpdateChannel(info: candidate), "missing \(key)")
        }
        for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var candidate = info
            candidate[key] = false
            XCTAssertNil(PublicUpdateChannel(info: candidate), key)
        }
        for key in ["SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"] {
            var candidate = info
            candidate[key] = true
            XCTAssertNil(PublicUpdateChannel(info: candidate), key)
        }
        var candidate = info
        candidate["SUSignedFeedFailureExpirationInterval"] = 60
        XCTAssertNil(PublicUpdateChannel(info: candidate))
    }

    func testOldAutomaticCheckOptOutWinsWithoutChangingSavedPreferences() {
        let suite = "synthetic-public-updates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(PublicUpdateChannel.automaticChecksEnabled(in: defaults))
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        XCTAssertFalse(PublicUpdateChannel.automaticChecksEnabled(in: defaults))
        defaults.set(true, forKey: AutomaticUpdateSchedule.preferenceKey)
        XCTAssertTrue(PublicUpdateChannel.automaticChecksEnabled(in: defaults))
        defaults.set(false, forKey: AutomaticUpdateSchedule.preferenceKey)
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        let before = defaults.persistentDomain(forName: suite)! as NSDictionary
        XCTAssertFalse(PublicUpdateChannel.automaticChecksEnabled(in: defaults))
        XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
    }

#if canImport(Sparkle)
    @MainActor
    func testNativeDriverValuesReachControllerBeforeTheNextRunLoopTurn() {
        let suite = "synthetic-native-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousCheck = Date(timeIntervalSince1970: 1_750_000_000)
        defaults.set(previousCheck, forKey: AutomaticUpdateSchedule.lastSuccessfulCheckKey)
        let credentials = UpdateCredentialStore(load: { nil }, save: { _ in }, remove: {})
        let controller = AppUpdateController(enabled: false, credentials: credentials, defaults: defaults)
        let driver = SparkleUpdateDriver(defaults: defaults, info: info)!
        controller.observeNativeState(driver.states)
        XCTAssertEqual(controller.lastSuccessfulCheck, previousCheck)
        XCTAssertTrue(controller.automaticChecksEnabled)

        // Sparkle callbacks run inside its own alert/run-loop modes. The
        // controller must receive the new published payload immediately,
        // without scheduling a later read of the driver's stored properties.
        driver.setAutomaticChecksEnabled(false)
        XCTAssertFalse(controller.automaticChecksEnabled)
        driver.canQuit = { false }
        XCTAssertTrue(driver.postponeRelaunchIfNeeded {})
        XCTAssertEqual(controller.error, driver.error)
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(controller.busy)
        XCTAssertNil(defaults.object(forKey: AutomaticUpdateSchedule.lastAttemptKey), "No updater or credential operation starts")
    }

    @MainActor
    func testNativeCheckResultsReplaceBusyStatusAndCheckDateWithoutDeferredReads() {
        let suite = "synthetic-native-check-result-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = UpdateCredentialStore(load: { nil }, save: { _ in }, remove: {})
        let controller = AppUpdateController(enabled: false, credentials: credentials, defaults: defaults)
        let previousCheck = Date(timeIntervalSince1970: 1_750_000_000)
        let freshCheck = previousCheck.addingTimeInterval(120)
        let states = CurrentValueSubject<SparkleUpdateDriver.State, Never>(.init(
            status: "Checking for updates…", error: nil, availableVersion: nil,
            availableBuild: nil, busy: true, lastSuccessfulCheck: previousCheck,
            automaticChecksEnabled: true))
        controller.observeNativeState(states.eraseToAnyPublisher())
        XCTAssertTrue(controller.busy)

        states.send(.init(status: "You are up to date.", error: nil, availableVersion: nil,
            availableBuild: nil, busy: false, lastSuccessfulCheck: freshCheck,
            automaticChecksEnabled: true))
        XCTAssertEqual(controller.status, "You are up to date.")
        XCTAssertEqual(controller.lastSuccessfulCheck, freshCheck)
        XCTAssertFalse(controller.busy)

        states.send(.init(status: "Version 1.7.1 is ready to install.", error: nil,
            availableVersion: "1.7.1", availableBuild: 65, busy: false,
            lastSuccessfulCheck: freshCheck, automaticChecksEnabled: true))
        XCTAssertEqual(controller.availableVersion, "1.7.1")
        XCTAssertEqual(controller.availableBuild, 65)
        states.send(.init(status: "Update check could not be completed.", error: "Synthetic network failure",
            availableVersion: nil, availableBuild: nil, busy: false,
            lastSuccessfulCheck: freshCheck, automaticChecksEnabled: false))
        XCTAssertEqual(controller.error, "Synthetic network failure")
        XCTAssertNil(controller.availableVersion)
        XCTAssertNil(controller.availableBuild)
        XCTAssertEqual(controller.lastSuccessfulCheck, freshCheck)
        XCTAssertFalse(controller.automaticChecksEnabled)
    }

    @MainActor
    func testDriverInitializationAndEditVetoDoNotStartAnUpdateOrInvokeInstallation() {
        let suite = "synthetic-public-update-driver-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(SparkleUpdateDriver(enabled: false, defaults: defaults, info: info))
        XCTAssertNil(SparkleUpdateDriver(defaults: defaults, info: [:]))
        let driver = SparkleUpdateDriver(defaults: defaults, info: info)!
        for selector in ["updater:mayPerformUpdateCheck:error:", "updater:didFindValidUpdate:",
                         "updaterDidNotFindUpdate:", "updater:userDidMakeChoice:forUpdate:state:",
                         "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:"] {
            XCTAssertTrue(driver.responds(to: NSSelectorFromString(selector)), "Sparkle delegate \(selector)")
        }
        var installCalls = 0
        driver.canQuit = { false }
        XCTAssertTrue(driver.postponeRelaunchIfNeeded { installCalls += 1 })
        XCTAssertEqual(installCalls, 0)
        XCTAssertNotNil(driver.error)
        XCTAssertFalse(driver.busy)
        driver.canQuit = { true }
        XCTAssertFalse(driver.postponeRelaunchIfNeeded { installCalls += 1 })
        XCTAssertEqual(installCalls, 0, "Sparkle, not the veto check, owns invoking its installation handler")
        XCTAssertNil(defaults.object(forKey: AutomaticUpdateSchedule.lastAttemptKey))
        driver.stop()
    }
#endif
}
