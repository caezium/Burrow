//
//  UpdateWorkflow.swift
//  Burrow
//
//  Shared state and verification primitives for third-party app updates.
//  The UI owns orchestration; this file keeps network failure classification,
//  Electron feed parsing, and replacement identity checks small and testable.
//

import Foundation
import AppKit
import CryptoKit
import Security
import Darwin

enum BundleVerificationFailure: String, Equatable, Sendable {
    case bundleIdentityChanged
    case signingIdentityChanged
    case invalidSignature

    var message: String {
        switch self {
        case .bundleIdentityChanged:
            return NSLocalizedString("The downloaded app has a different bundle identifier.", comment: "")
        case .signingIdentityChanged:
            return NSLocalizedString("The downloaded app is signed by a different developer.", comment: "")
        case .invalidSignature:
            return NSLocalizedString("macOS could not validate the downloaded app's code signature.", comment: "")
        }
    }
}

enum UpdateFailure: Error, Equatable, Sendable {
    case offline
    case timeout
    case network(code: Int)
    case http(status: Int, retryable: Bool)
    case invalidResponse
    case decoding
    case verification(BundleVerificationFailure)
    case installation(String)
    case unsupported(String)
    case cancelled

    var canRetry: Bool {
        switch self {
        case .offline, .timeout, .network, .decoding:
            return true
        case let .http(_, retryable):
            return retryable
        case .installation:
            return true
        case .invalidResponse, .verification, .unsupported, .cancelled:
            return false
        }
    }

    var message: String {
        switch self {
        case .offline:
            return NSLocalizedString("Offline — reconnect and retry.", comment: "")
        case .timeout:
            return NSLocalizedString("The update server timed out. Retry when the connection is stable.", comment: "")
        case let .network(code):
            return String(format: NSLocalizedString("The network request failed (%d).", comment: ""), code)
        case let .http(status, retryable):
            if retryable {
                return String(format: NSLocalizedString("The update server failed (HTTP %d). You can retry.", comment: ""), status)
            }
            return String(format: NSLocalizedString("The update server refused the request (HTTP %d).", comment: ""), status)
        case .invalidResponse:
            return NSLocalizedString("The update server returned an invalid response.", comment: "")
        case .decoding:
            return NSLocalizedString("The update metadata was malformed.", comment: "")
        case let .verification(reason):
            return reason.message
        case let .installation(message), let .unsupported(message):
            return message
        case .cancelled:
            return NSLocalizedString("Update cancelled.", comment: "")
        }
    }
}

enum UpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case available
    case downloading(progress: Double?)
    case verifying
    case readyToInstall
    case installing
    case waitingForRestart
    case completed
    case handedOff(String)
    case failed(UpdateFailure)

    var canRetry: Bool {
        if case let .failed(failure) = self { return failure.canRetry }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing, .waitingForRestart:
            return true
        default:
            return false
        }
    }

    var accessibilityValue: String {
        switch self {
        case .idle:
            return NSLocalizedString("Not checked", comment: "")
        case .checking:
            return NSLocalizedString("Checking for updates", comment: "")
        case .available:
            return NSLocalizedString("Update available", comment: "")
        case let .downloading(progress):
            guard let progress else { return NSLocalizedString("Downloading", comment: "") }
            return String(format: NSLocalizedString("Downloading, %.0f percent", comment: ""), progress * 100)
        case .verifying:
            return NSLocalizedString("Verifying downloaded update", comment: "")
        case .readyToInstall:
            return NSLocalizedString("Ready to install and restart", comment: "")
        case .installing:
            return NSLocalizedString("Installing update", comment: "")
        case .waitingForRestart:
            return NSLocalizedString("Waiting for the app to restart", comment: "")
        case .completed:
            return NSLocalizedString("Update installed", comment: "")
        case let .handedOff(destination):
            return String(format: NSLocalizedString("Continue in %@", comment: ""), destination)
        case let .failed(failure):
            return failure.message
        }
    }
}

enum UpdateHTTPOutcome: Equatable, Sendable {
    case success(Data)
    case failure(UpdateFailure)
}

enum UpdateHTTP {
    static func classify(data: Data?, response: URLResponse?, error: Error?) -> UpdateHTTPOutcome {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed:
                return .failure(.offline)
            case .timedOut:
                return .failure(.timeout)
            case .cancelled:
                return .failure(.cancelled)
            default:
                return .failure(.network(code: urlError.errorCode))
            }
        }
        if let error = error as NSError? {
            return .failure(.network(code: error.code))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.invalidResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let retryable = http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode)
            return .failure(.http(status: http.statusCode, retryable: retryable))
        }
        guard let data, !data.isEmpty else { return .failure(.decoding) }
        return .success(data)
    }

    static func fetch(_ url: URL, timeout: TimeInterval = 15) async -> UpdateHTTPOutcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if url.scheme?.lowercased() == "https",
               response.url?.scheme?.lowercased() != "https" {
                return .failure(.invalidResponse)
            }
            return classify(data: data, response: response, error: nil)
        } catch {
            return classify(data: nil, response: nil, error: error)
        }
    }
}

struct ElectronFeedConfiguration: Equatable, Sendable {
    let latestYAMLURL: URL

    /// electron-builder's generic provider is the only direct replacement
    /// format supported here. GitHub/S3/private providers hand off to the
    /// app's own updater because reconstructing their authentication and
    /// channel rules would be unsafe.
    static func parse(_ data: Data) -> ElectronFeedConfiguration? {
        guard let text = String(data: data, encoding: .utf8),
              scalar("provider", in: text)?.lowercased() == "generic",
              let rawURL = scalar("url", in: text),
              let base = URL(string: rawURL),
              base.scheme?.lowercased() == "https" else { return nil }
        return ElectronFeedConfiguration(latestYAMLURL: base.appendingPathComponent("latest-mac.yml"))
    }

    static func read(appPath: String) -> ElectronFeedConfiguration? {
        let path = (appPath as NSString).appendingPathComponent("Contents/Resources/app-update.yml")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data)
    }

    fileprivate static func scalar(_ key: String, in yaml: String) -> String? {
        for rawLine in yaml.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let candidate = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard candidate == key else { continue }
            return unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    fileprivate static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return value }
        return String(value.dropFirst().dropLast())
    }
}

struct ElectronUpdateDescriptor: Equatable, Sendable {
    let version: String
    let archiveURL: URL
    let sha512: Data

    static func parse(_ data: Data, relativeTo metadataURL: URL) -> ElectronUpdateDescriptor? {
        guard let text = String(data: data, encoding: .utf8),
              let version = ElectronFeedConfiguration.scalar("version", in: text),
              !version.isEmpty else { return nil }

        var archivePath: String?
        var digest: String?
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if archivePath == nil, trimmed.hasPrefix("- url:") {
                archivePath = ElectronFeedConfiguration.unquote(
                    String(trimmed.dropFirst("- url:".count)).trimmingCharacters(in: .whitespaces)
                )
            } else if archivePath == nil, trimmed.hasPrefix("path:") {
                archivePath = ElectronFeedConfiguration.unquote(
                    String(trimmed.dropFirst("path:".count)).trimmingCharacters(in: .whitespaces)
                )
            }
            if digest == nil, trimmed.hasPrefix("sha512:") {
                digest = ElectronFeedConfiguration.unquote(
                    String(trimmed.dropFirst("sha512:".count)).trimmingCharacters(in: .whitespaces)
                )
            }
        }

        guard let archivePath, let digest, let sha512 = Data(base64Encoded: digest) else { return nil }
        let archiveURL: URL?
        if let absolute = URL(string: archivePath), absolute.scheme != nil {
            archiveURL = absolute
        } else {
            archiveURL = URL(string: archivePath, relativeTo: metadataURL.deletingLastPathComponent())?.absoluteURL
        }
        guard let archiveURL,
              archiveURL.scheme?.lowercased() == "https",
              archiveURL.pathExtension.lowercased() == "zip" else { return nil }
        return ElectronUpdateDescriptor(version: version, archiveURL: archiveURL, sha512: sha512)
    }
}

struct BundleUpdateIdentity: Equatable, Sendable {
    let bundleID: String
    let signingIdentifier: String?
    let teamIdentifier: String?
    let signatureValid: Bool

    func verificationFailure(comparedWith candidate: BundleUpdateIdentity) -> BundleVerificationFailure? {
        guard candidate.signatureValid else { return .invalidSignature }
        guard bundleID == candidate.bundleID else { return .bundleIdentityChanged }
        guard signatureValid,
              let signingIdentifier, let teamIdentifier,
              !signingIdentifier.isEmpty, !teamIdentifier.isEmpty,
              signingIdentifier == candidate.signingIdentifier,
              teamIdentifier == candidate.teamIdentifier else { return .signingIdentityChanged }
        return nil
    }

    static func read(appURL: URL) -> BundleUpdateIdentity? {
        guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        // Validate every architecture in a universal app. Checking only the
        // host architecture could otherwise admit a tampered alternate slice.
        let checkAllArchitectures = SecCSFlags(rawValue: 1 << 0)
        let valid = SecStaticCodeCheckValidity(staticCode, checkAllArchitectures, nil) == errSecSuccess
        var information: CFDictionary?
        let signingInformation: UInt32 = 0x2
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: signingInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any] else {
            return BundleUpdateIdentity(
                bundleID: bundleID,
                signingIdentifier: nil,
                teamIdentifier: nil,
                signatureValid: valid
            )
        }
        return BundleUpdateIdentity(
            bundleID: bundleID,
            signingIdentifier: values[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            signatureValid: valid
        )
    }
}

struct StagedElectronUpdate: Sendable {
    let targetURL: URL
    let candidateURL: URL
    let stagingDirectory: URL
    let expectedIdentity: BundleUpdateIdentity

    func discard() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}

enum PrivateUpdateDirectory {
    /// `mkdtemp` creates the directory atomically, so concurrent update runs
    /// cannot select the same path or follow a pre-planted symlink. Tighten
    /// its permissions before any downloaded data is written.
    static func create(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        var template = parent
            .appendingPathComponent("BurrowUpdate.XXXXXX", isDirectory: true)
            .path
            .utf8CString
        let created = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!)
        }
        guard created != nil else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
            )
        }
        let path = template.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard chmod(url.path, S_IRWXU) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: url)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
        return url
    }
}

enum ElectronStageOutcome: Sendable {
    case ready(StagedElectronUpdate)
    case failure(UpdateFailure)
}

enum ElectronInstallOutcome: Sendable {
    case installed
    case failure(UpdateFailure)
}

enum ElectronReplacementInstaller {
    static func boundaryVerificationFailure(
        for staged: StagedElectronUpdate,
        readIdentity: (URL) -> BundleUpdateIdentity? = { BundleUpdateIdentity.read(appURL: $0) }
    ) -> UpdateFailure? {
        guard let targetIdentity = readIdentity(staged.targetURL) else {
            return .verification(.bundleIdentityChanged)
        }
        if let failure = staged.expectedIdentity.verificationFailure(comparedWith: targetIdentity) {
            return .verification(failure)
        }
        guard let candidateIdentity = readIdentity(staged.candidateURL) else {
            return .verification(.invalidSignature)
        }
        if let failure = staged.expectedIdentity.verificationFailure(comparedWith: candidateIdentity) {
            return .verification(failure)
        }
        return nil
    }

    static func stage(
        appPath: String,
        descriptor: ElectronUpdateDescriptor
    ) async -> ElectronStageOutcome {
        let targetURL = URL(fileURLWithPath: appPath, isDirectory: true)
        guard let expectedIdentity = BundleUpdateIdentity.read(appURL: targetURL),
              expectedIdentity.verificationFailure(comparedWith: expectedIdentity) == nil else {
            return .failure(.unsupported(NSLocalizedString(
                "This Electron app does not expose a verifiable signing identity, so Burrow opened its own updater instead.",
                comment: ""
            )))
        }

        let root: URL
        do {
            root = try PrivateUpdateDirectory.create()
        } catch {
            return .failure(.installation(error.localizedDescription))
        }

        let archive = root.appendingPathComponent("update.zip")
        let extracted = root.appendingPathComponent("Extracted", isDirectory: true)
        do {
            let (temporaryDownload, response) = try await URLSession.shared.download(from: descriptor.archiveURL)
            guard let http = response as? HTTPURLResponse,
                  response.url?.scheme?.lowercased() == "https" else {
                throw UpdateFailure.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw UpdateFailure.http(
                    status: http.statusCode,
                    retryable: http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode)
                )
            }
            try FileManager.default.moveItem(at: temporaryDownload, to: archive)
            guard try sha512(of: archive) == descriptor.sha512 else {
                throw UpdateFailure.verification(.invalidSignature)
            }
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            let extraction = try MoEngine.shared.capture(
                MoCommand(
                    target: .executable("/usr/bin/ditto"),
                    args: ["-x", "-k", archive.path, extracted.path],
                    timeout: 120
                )
            )
            guard extraction.exitCode == 0 else {
                throw UpdateFailure.installation(NSLocalizedString("The downloaded update could not be extracted.", comment: ""))
            }
            guard let candidate = firstApplication(in: extracted),
                  let candidateIdentity = BundleUpdateIdentity.read(appURL: candidate) else {
                throw UpdateFailure.verification(.invalidSignature)
            }
            if let failure = expectedIdentity.verificationFailure(comparedWith: candidateIdentity) {
                throw UpdateFailure.verification(failure)
            }
            return .ready(StagedElectronUpdate(
                targetURL: targetURL,
                candidateURL: candidate,
                stagingDirectory: root,
                expectedIdentity: expectedIdentity
            ))
        } catch let failure as UpdateFailure {
            try? FileManager.default.removeItem(at: root)
            return .failure(failure)
        } catch let error as URLError {
            try? FileManager.default.removeItem(at: root)
            let failure: UpdateFailure
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed:
                failure = .offline
            case .timedOut:
                failure = .timeout
            case .cancelled:
                failure = .cancelled
            default:
                failure = .network(code: error.errorCode)
            }
            return .failure(failure)
        } catch {
            try? FileManager.default.removeItem(at: root)
            return .failure(.installation(error.localizedDescription))
        }
    }

    @MainActor
    static func install(_ staged: StagedElectronUpdate) async -> ElectronInstallOutcome {
        defer { staged.discard() }
        guard let currentIdentity = BundleUpdateIdentity.read(appURL: staged.targetURL),
              staged.expectedIdentity.verificationFailure(comparedWith: currentIdentity) == nil else {
            return .failure(.verification(.bundleIdentityChanged))
        }
        guard FileManager.default.isWritableFile(atPath: staged.targetURL.deletingLastPathComponent().path) else {
            return .failure(.unsupported(NSLocalizedString(
                "Burrow cannot safely replace this app in its current folder. Open the app and use its own updater.",
                comment: ""
            )))
        }

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: staged.expectedIdentity.bundleID
        )
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !running.contains(where: { !$0.isTerminated }) else {
            return .failure(.installation(NSLocalizedString(
                "The app did not quit, so Burrow left the existing installation unchanged.",
                comment: ""
            )))
        }

        // Revalidate again after waiting for termination. An app or another
        // updater may have replaced the target while the quit request ran.
        // Both bundles have remained on disk while the target app quit.
        // Re-read them at the replacement boundary so a stale target or
        // swapped candidate fails closed.
        if let failure = boundaryVerificationFailure(for: staged) {
            return .failure(failure)
        }

        let backupName = ".Burrow Update Backup \(UUID().uuidString).app"
        let backupURL = staged.targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            _ = try FileManager.default.replaceItemAt(
                staged.targetURL,
                withItemAt: staged.candidateURL,
                backupItemName: backupName,
                options: []
            )
            guard let installedIdentity = BundleUpdateIdentity.read(appURL: staged.targetURL),
                  staged.expectedIdentity.verificationFailure(comparedWith: installedIdentity) == nil else {
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    _ = try? FileManager.default.replaceItemAt(staged.targetURL, withItemAt: backupURL)
                }
                return .failure(.verification(.signingIdentityChanged))
            }
            try? FileManager.default.removeItem(at: backupURL)
            let configuration = NSWorkspace.OpenConfiguration()
            _ = try? await NSWorkspace.shared.openApplication(
                at: staged.targetURL,
                configuration: configuration
            )
            return .installed
        } catch {
            return .failure(.installation(error.localizedDescription))
        }
    }

    private static func sha512(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA512()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    private static func firstApplication(in directory: URL) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            return url
        }
        return nil
    }
}
