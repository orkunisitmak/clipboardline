import Foundation

/// The official anonymous channel is selected by the signed application, never
/// by a remote feed, preferences or a saved private GitHub connection.
struct PublicUpdateChannel: Equatable {
    static let repository = "orkunisitmak/clipboardline-desktop"
    static let legacyRepository = "orkunisitmak/clipboardline-app"
    static let legacyFeed = "https://github.com/orkunisitmak/clipboardline-app/releases/latest/download/appcast.xml"
    static let feed = "https://github.com/orkunisitmak/clipboardline-desktop/releases/latest/download/appcast.xml"
    static let publicKey = "ASY6h/Y7xsg4fUmA8TleW6XhbhOtn5M6ql4eqq8o3sE="

    let feedURL: URL

    init?(info: [String: Any]) {
        let repository = info["ClipboardLinePublicUpdateRepository"] as? String
        let feed = info["SUFeedURL"] as? String
        let knownChannel = (repository == Self.repository && feed == Self.feed) ||
            (repository == Self.legacyRepository && feed == Self.legacyFeed)
        guard info["CFBundleIdentifier"] as? String == "local.clipboardline.review",
              knownChannel,
              info["SUPublicEDKey"] as? String == Self.publicKey,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue == 0,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUAutomaticallyUpdate"] as? Bool == false,
              info["SUEnableSystemProfiling"] as? Bool == false,
              let feed, let url = URL(string: feed) else { return nil }
        feedURL = url
    }

    /// Preserve the existing update opt-out when moving from the private client.
    /// No credential is read, authorized, migrated or deleted by this operation.
    static func automaticChecksEnabled(in defaults: UserDefaults) -> Bool {
        if let previous = defaults.object(forKey: AutomaticUpdateSchedule.preferenceKey) as? Bool { return previous }
        return defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
    }
}
