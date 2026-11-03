import Foundation

/// Inbox mode: Tendedero takes over where screenshots go.
///
/// It changes the macOS screenshot settings in the Options menu of
/// Cmd+Shift+5: the floating thumbnail is turned off, so the file is written
/// at once instead of five seconds later, and captures are saved as files in
/// Tendedero's own folder, so the Desktop only gets what you keep. Saving to
/// the clipboard or Preview would leave nothing to hang, and a click on the
/// line copies anyway.
/// Screen recordings go there too, and hang on the line like screenshots.
///
/// The previous values are saved first and put back when the mode is turned
/// off or the app quits, so macOS is never left pointing at a folder nobody
/// is watching.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    /// macOS 26 and earlier read "location". macOS 27 reads
    /// "location-screenshot" and ignores the old key, so both are written.
    private static let locationKey = "location" as CFString
    private static let screenshotLocationKey = "location-screenshot" as CFString
    /// macOS 27 keeps screen recordings apart, in "location-screenrecording".
    /// Earlier versions send them wherever "location" points.
    private static let recordingLocationKey = "location-screenrecording" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString
    /// Whether a capture is saved as a file or sent to the clipboard, Preview
    /// and so on. macOS 26 and earlier read "target"; macOS 27 has one for
    /// screenshots and one for recordings.
    private static let targetKey = "target" as CFString
    private static let screenshotTargetKey = "target-screenshot" as CFString
    private static let recordingTargetKey = "target-screenrecording" as CFString

    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

    /// macOS screenshot preferences go through this seam, so a test can run the
    /// real apply and restore logic without changing the user's own settings.
    protocol Preferences {
        func value(_ key: CFString) -> Any?
        func set(_ key: CFString, _ value: Any?)
    }

    struct SystemPreferences: Preferences {
        func value(_ key: CFString) -> Any? { CFPreferencesCopyAppValue(key, domain) }
        func set(_ key: CFString, _ value: Any?) {
            CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
            // Writes through cfprefsd, so the screenshot service sees it at once.
            CFPreferencesAppSynchronize(domain)
        }
    }

    static var preferences: Preferences = SystemPreferences()
    /// The defaults domain holding the user's choice and the saved settings.
    static var defaults: UserDefaults = .standard

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/Screenshots", isDirectory: true)
    }()

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { defaults.bool(forKey: offeredKey) }
        set { defaults.set(newValue, forKey: offeredKey) }
    }

    /// Whether macOS is currently sending screenshots to our folder.
    static var isApplied: Bool {
        guard let current = preferences.value(locationKey) as? String else { return false }
        return URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL
            == folder.standardizedFileURL
    }

    /// Inbox holds the screenshots only while capture is running. Private mode
    /// hands the user's own destination back, and a relaunch while it is on
    /// must not quietly take it over: otherwise the screenshots land in the
    /// app's folder while every watcher skips them, and appear nowhere.
    static func reconcile(enabled: Bool, paused: Bool) {
        if enabled && !paused { apply() } else { restore() }
    }

    /// Launch and the private mode switch only touch an enabled Inbox. The
    /// folder is shared between builds, but the saved settings live in each
    /// bundle's own defaults, so a build with Inbox off would otherwise restore
    /// from empty settings and reset the user's screenshot destination.
    static func reconcileIfEnabled(paused: Bool) {
        if isEnabled { reconcile(enabled: true, paused: paused) }
    }

    static func apply() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never save our own values as the "previous" ones, for example after
        // a crash left them applied.
        var saved = defaults.dictionary(forKey: savedKey) ?? [:]
        if !isApplied {
            saved = [:]
            saved["location"] = preferences.value(locationKey) as? String
            saved["locationScreenshot"] = preferences.value(screenshotLocationKey) as? String
            saved["thumbnail"] = preferences.value(thumbnailKey) as? Bool
        }
        // Recordings and the target came later: settings saved by an earlier
        // version lack them, and the value macOS has now is still the user's own.
        if saved["recordingSaved"] == nil {
            saved["locationRecording"] = preferences.value(recordingLocationKey) as? String
            saved["recordingSaved"] = true
        }
        if saved["targetSaved"] == nil {
            saved["target"] = preferences.value(targetKey) as? String
            saved["targetScreenshot"] = preferences.value(screenshotTargetKey) as? String
            saved["targetRecording"] = preferences.value(recordingTargetKey) as? String
            saved["targetSaved"] = true
        }
        defaults.set(saved, forKey: savedKey)
        set(locationKey, folder.path)
        set(screenshotLocationKey, folder.path)
        set(recordingLocationKey, folder.path)
        set(targetKey, "file")
        set(screenshotTargetKey, "file")
        set(recordingTargetKey, "file")
        set(thumbnailKey, false)
    }

    static func restore() {
        guard isApplied else { return }
        let saved = defaults.dictionary(forKey: savedKey) ?? [:]
        set(locationKey, saved["location"])
        set(screenshotLocationKey, saved["locationScreenshot"])
        set(recordingLocationKey, saved["locationRecording"])
        set(targetKey, saved["target"])
        set(screenshotTargetKey, saved["targetScreenshot"])
        set(recordingTargetKey, saved["targetRecording"])
        set(thumbnailKey, saved["thumbnail"])
        defaults.removeObject(forKey: savedKey)
    }

    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        preferences.set(key, value)
    }
}
