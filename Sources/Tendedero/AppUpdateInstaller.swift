import Foundation
import CryptoKit
import Security
import Darwin

enum AppUpdateInstallError: Error, LocalizedError {
    case rejected(String)
    var errorDescription: String? { if case let .rejected(message) = self { return message }; return nil }
}

struct AppUpdateJob: Codable {
    let candidate: URL
    let activeApp: URL
    let manifest: UpdateManifest
    let workDirectory: URL
    let parentPID: Int32
    let oldExecutableSHA256: String
}

/// Uses only public code-signing information. Client Macs need neither the
/// developer's signing key, Python, Xcode nor an Accessibility permission.
enum AppUpdateInstaller {
    static let identifier = "local.clipboardline.review"
    static let helperName = "ClipboardLineUpdateInstaller"
    private static let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw AppUpdateInstallError.rejected(message) }
    }

    static func sha256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func info(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppUpdateInstallError.rejected(L("The update has no application information."))
        }
        try require(value["CFBundleIdentifier"] as? String == identifier, L("The update belongs to another application."))
        try require(value["CFBundleExecutable"] as? String == "ClipboardLine", L("The update executable is invalid."))
        return value
    }

    static func executable(_ app: URL) -> URL { app.appendingPathComponent("Contents/MacOS/ClipboardLine") }

    static func privateDirectory(_ url: URL, create: Bool = false) throws {
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try require(values.isDirectory == true && values.isSymbolicLink != true &&
            url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL &&
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() &&
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
            L("The update staging directory is not private."))
    }

    private struct Identity {
        let code: SecStaticCode
        let requirement: SecRequirement
        let requirementData: Data
        let certificate: Data
    }

    private static func identity(_ app: URL, architecture: Int32) throws -> Identity {
        var code: SecStaticCode?
        let attributes = [kSecCodeAttributeArchitecture as String: NSNumber(value: architecture)] as CFDictionary
        try require(SecStaticCodeCreateWithPathAndAttributes(app as CFURL, [], attributes, &code) == errSecSuccess,
                    L("The update is missing a supported architecture."))
        guard let code else { throw AppUpdateInstallError.rejected(L("The application signature is missing.")) }
        try require(SecStaticCodeCheckValidity(code, validationFlags, nil) == errSecSuccess, L("The application signature is invalid."))
        var metadata: CFDictionary?
        try require(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &metadata) == errSecSuccess,
                    L("The signing certificate could not be read."))
        let values = metadata as? [String: Any]
        guard values?[kSecCodeInfoIdentifier as String] as? String == identifier,
              let certificates = values?[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else {
            throw AppUpdateInstallError.rejected(L("An ad-hoc or unrelated application cannot install updates."))
        }
        var requirement: SecRequirement?
        try require(SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, L("The application identity is missing."))
        guard let requirement else { throw AppUpdateInstallError.rejected(L("The application identity is missing.")) }
        var data: CFData?
        try require(SecRequirementCopyData(requirement, [], &data) == errSecSuccess, L("The application identity could not be read."))
        guard let data else { throw AppUpdateInstallError.rejected(L("The application identity is empty.")) }
        return Identity(code: code, requirement: requirement, requirementData: data as Data, certificate: SecCertificateCopyData(leaf) as Data)
    }

    static func validate(candidate: URL, activeApp: URL, manifest: UpdateManifest) throws {
        let old = try info(activeApp), next = try info(candidate)
        guard let oldBuild = Int(old["CFBundleVersion"] as? String ?? "") else { throw AppUpdateInstallError.rejected(L("The installed build is invalid.")) }
        try require(manifest.build > oldBuild && next["CFBundleVersion"] as? String == String(manifest.build) &&
                    next["CFBundleShortVersionString"] as? String == manifest.version, L("The downloaded version does not match the release."))
        let version = manifest.minimumSystemVersion.split(separator: ".").compactMap { Int($0) }
        try require(!version.isEmpty && ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
            majorVersion: version[0], minorVersion: version.count > 1 ? version[1] : 0, patchVersion: version.count > 2 ? version[2] : 0)),
            L("This update needs a newer version of macOS."))
        var baseline: Identity?
        for architecture: Int32 in [0x0100000c, 0x01000007] { // universal arm64 and x86_64
            let previous = try identity(activeApp, architecture: architecture)
            let incoming = try identity(candidate, architecture: architecture)
            try require(previous.certificate == incoming.certificate && previous.requirementData == incoming.requirementData,
                        L("The update changed the trusted application identity."))
            try require(SecStaticCodeCheckValidity(incoming.code, validationFlags, previous.requirement) == errSecSuccess &&
                        SecStaticCodeCheckValidity(previous.code, validationFlags, incoming.requirement) == errSecSuccess,
                        L("The update is not signed by the installed application's publisher."))
            if let baseline { try require(previous.certificate == baseline.certificate && previous.requirementData == baseline.requirementData,
                                          L("The installed architectures have different signing identities.")) }
            else { baseline = previous }
        }
    }

    static func prepare(archive: URL, manifest: UpdateManifest, activeApp: URL, workDirectory: URL) throws -> URL {
        try privateDirectory(workDirectory)
        let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
        try require(size?.int64Value == manifest.archiveSize && manifest.archiveSize <= AppUpdatePolicy.maxArchiveSize,
                    L("The update download is incomplete."))
        try require(try sha256(archive) == manifest.archiveSHA256, L("The update download failed its integrity check."))
        // The manifest was Ed25519-verified by the caller; authenticate archive
        // bytes before extracting anything, then independently verify all code.
        let extracted = workDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try require(!FileManager.default.fileExists(atPath: extracted.path), L("The update staging directory is already in use."))
        try privateDirectory(extracted, create: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, L("The update archive could not be opened."))
        let candidate = extracted.appendingPathComponent("ClipboardLine Review.app")
        try validate(candidate: candidate, activeApp: activeApp, manifest: manifest)
        return candidate
    }

    static func launch(candidate: URL, activeApp: URL, manifest: UpdateManifest, workDirectory: URL, parentPID: Int32) throws {
        try privateDirectory(workDirectory)
        try validate(candidate: candidate, activeApp: activeApp, manifest: manifest)
        try require(activeApp.standardizedFileURL == activeApp.resolvingSymlinksInPath().standardizedFileURL &&
                    activeApp.lastPathComponent == "ClipboardLine Review.app", L("The installed application path is unsafe."))
        try require(FileManager.default.isWritableFile(atPath: activeApp.deletingLastPathComponent().path),
                    L("Move the app to a writable Applications folder before updating."))
        let helper = activeApp.appendingPathComponent("Contents/Helpers/\(helperName)")
        try require(FileManager.default.isExecutableFile(atPath: helper.path), L("The update installer is missing."))
        let job = AppUpdateJob(candidate: candidate, activeApp: activeApp, manifest: manifest, workDirectory: workDirectory,
                               parentPID: parentPID, oldExecutableSHA256: try sha256(executable(activeApp)))
        let file = workDirectory.appendingPathComponent("install-job.json")
        try JSONEncoder().encode(job).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let process = Process(); process.executableURL = helper; process.arguments = [file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func verifyOriginal(_ job: AppUpdateJob) throws {
        _ = try info(job.activeApp)
        try require(try sha256(executable(job.activeApp)) == job.oldExecutableSHA256, "The previous application could not be verified.")
        let arm = try identity(job.activeApp, architecture: 0x0100000c)
        let intel = try identity(job.activeApp, architecture: 0x01000007)
        try require(arm.certificate == intel.certificate && arm.requirementData == intel.requirementData,
                    "The previous application has inconsistent signing identities.")
    }

    /// The parent has quit normally before this operation. Rename within its
    /// writable parent directory; no elevated helper and no user-data changes.
    static func install(_ job: AppUpdateJob, beforeCommit: (() throws -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        try privateDirectory(job.workDirectory)
        let active = job.activeApp.standardizedFileURL
        try require(active == active.resolvingSymlinksInPath().standardizedFileURL && active.lastPathComponent == "ClipboardLine Review.app",
                    L("The installed application path is unsafe."))
        try require(try sha256(executable(active)) == job.oldExecutableSHA256, "The installed app changed while the update was waiting.")
        try validate(candidate: job.candidate, activeApp: active, manifest: job.manifest)
        let parent = active.deletingLastPathComponent()
        try require(fm.isWritableFile(atPath: parent.path), L("Move the app to a writable Applications folder before updating."))
        let transaction = parent.appendingPathComponent(".ClipboardLine-update-\(UUID().uuidString)", isDirectory: true)
        try privateDirectory(transaction, create: true)
        let staged = transaction.appendingPathComponent("ClipboardLine Review.app")
        // RENAME_SWAP exchanges both existing directory entries in one atomic
        // filesystem operation. After it, staged is the retained previous app.
        let backup = staged
        var replaced = false
        do {
            try fm.copyItem(at: job.candidate, to: staged)
            try validate(candidate: staged, activeApp: active, manifest: job.manifest)
            try beforeCommit?()
            try require(renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, active.path, UInt32(RENAME_SWAP)) == 0,
                        "The filesystem could not atomically replace the application.")
            replaced = true
            // Validate against the retained old bundle after the atomic swap.
            try validate(candidate: active, activeApp: backup, manifest: job.manifest)
            let receipt: [String: Any] = ["version": job.manifest.version, "build": job.manifest.build,
                "installedAt": ISO8601DateFormatter().string(from: Date()), "backup": backup.path, "application": active.path]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: job.workDirectory.appendingPathComponent("installed.json"), options: .atomic)
            // Retain the old app for rollback; data and preferences are untouched.
            return backup
        } catch {
            if replaced, fm.fileExists(atPath: backup.path) {
                try require(renameatx_np(AT_FDCWD, backup.path, AT_FDCWD, active.path, UInt32(RENAME_SWAP)) == 0,
                            "The update failed and could not restore the previous application. Its backup is retained.")
            }
            throw error
        }
    }
}
