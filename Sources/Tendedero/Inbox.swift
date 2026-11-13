import Foundation

enum InboxSettings {
    static let keys = [
        "location",
        "locationScreenshot",
        "locationRecording",
        "thumbnail",
        "target",
        "targetScreenshot",
        "targetRecording"
    ]

    static func isApplied(current: [String: Any], folder: URL) -> Bool {
        let location = current["locationScreenshot"] as? String ?? current["location"] as? String
        return path(location, matches: folder)
    }

    static func restorableKeys(current: [String: Any], folder: URL) -> Set<String> {
        Set(keys.filter { isManagedValue(current[$0], for: $0, folder: folder) })
    }

    static func userChangedKeys(current: [String: Any], folder: URL) -> Set<String> {
        Set(keys.filter { !isManagedValue(current[$0], for: $0, folder: folder) })
    }

    private static func isManagedValue(_ value: Any?, for key: String, folder: URL) -> Bool {
        switch key {
        case "location", "locationScreenshot", "locationRecording":
            return path(value as? String, matches: folder)
        case "thumbnail":
            return (value as? Bool) == false
        case "target", "targetScreenshot", "targetRecording":
            return (value as? String) == "file"
        default:
            return false
        }
    }

    private static func path(_ value: String?, matches folder: URL) -> Bool {
        guard let value else { return false }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
            == folder.standardizedFileURL
    }
}

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

    private static let preferences: [(String, CFString)] = [
        ("location", locationKey),
        ("locationScreenshot", screenshotLocationKey),
        ("locationRecording", recordingLocationKey),
        ("thumbnail", thumbnailKey),
        ("target", targetKey),
        ("targetScreenshot", screenshotTargetKey),
        ("targetRecording", recordingTargetKey)
    ]

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/Screenshots", isDirectory: true)
    }()

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    /// Whether macOS is currently sending screenshots to our folder.
    static var isApplied: Bool {
        InboxSettings.isApplied(current: currentSettings(), folder: folder)
    }

    static func apply() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let current = currentSettings()
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if saved.isEmpty {
            // Start a new snapshot before taking over any system settings.
            saved = current
        } else {
            // Older snapshots did not contain recording or target preferences.
            // Capture those before filling them with Inbox's values.
            if saved["recordingSaved"] == nil {
                saved["locationRecording"] = current["locationRecording"]
                saved["recordingSaved"] = true
            }
            if saved["targetSaved"] == nil {
                saved["target"] = current["target"]
                saved["targetScreenshot"] = current["targetScreenshot"]
                saved["targetRecording"] = current["targetRecording"]
                saved["targetSaved"] = true
            }

            // If macOS changed a preference while Inbox was active, remember
            // that choice before applying Inbox's values again.
            for key in InboxSettings.userChangedKeys(current: current, folder: folder) {
                if let value = current[key] {
                    saved[key] = value
                } else {
                    saved.removeValue(forKey: key)
                }
            }
        }
        saved["recordingSaved"] = true
        saved["targetSaved"] = true
        UserDefaults.standard.set(saved, forKey: savedKey)

        for (name, key) in preferences {
            set(key, managedValue(for: name))
        }
    }

    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        let restoreKeys = InboxSettings.restorableKeys(current: currentSettings(), folder: folder)
        for (name, key) in preferences where restoreKeys.contains(name) {
            set(key, saved[name])
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    private static func currentSettings() -> [String: Any] {
        var current: [String: Any] = [:]
        for (name, key) in preferences {
            if let value = CFPreferencesCopyAppValue(key, domain) {
                current[name] = value
            }
        }
        return current
    }

    private static func managedValue(for name: String) -> Any? {
        switch name {
        case "location", "locationScreenshot", "locationRecording":
            return folder.path
        case "thumbnail":
            return false
        case "target", "targetScreenshot", "targetRecording":
            return "file"
        default:
            return nil
        }
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
