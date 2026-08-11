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

@_silgen_name("removefileat")
private func descriptorRelativeRemoveFile(
    _ directoryFD: Int32,
    _ path: UnsafePointer<CChar>,
    _ state: OpaquePointer?,
    _ flags: UInt32
) -> Int32

enum BundleVerificationFailure: String, Equatable, Sendable {
    case bundleIdentityChanged
    case signingIdentityChanged
    case invalidSignature
    case artifactIdentityChanged

    var message: String {
        switch self {
        case .bundleIdentityChanged:
            return NSLocalizedString("The downloaded app has a different bundle identifier.", comment: "")
        case .signingIdentityChanged:
            return NSLocalizedString("The downloaded app is signed by a different developer.", comment: "")
        case .invalidSignature:
            return NSLocalizedString("macOS could not validate the downloaded app's code signature.", comment: "")
        case .artifactIdentityChanged:
            return NSLocalizedString("The app changed after Burrow verified it. Check for updates again.", comment: "")
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

struct BundleFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct BundleUpdateIdentity: Equatable, Sendable {
    let bundleID: String
    let signingIdentifier: String?
    let teamIdentifier: String?
    let signatureValid: Bool
    let version: String?
    let build: String?
    let codeDirectoryHash: Data?
    let fileIdentity: BundleFileIdentity?

    init(
        bundleID: String,
        signingIdentifier: String?,
        teamIdentifier: String?,
        signatureValid: Bool,
        version: String? = nil,
        build: String? = nil,
        codeDirectoryHash: Data? = nil,
        fileIdentity: BundleFileIdentity? = nil
    ) {
        self.bundleID = bundleID
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.signatureValid = signatureValid
        self.version = version
        self.build = build
        self.codeDirectoryHash = codeDirectoryHash
        self.fileIdentity = fileIdentity
    }

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

    func artifactVerificationFailure(
        comparedWith current: BundleUpdateIdentity,
        requireSameFile: Bool = true
    ) -> BundleVerificationFailure? {
        if let failure = verificationFailure(comparedWith: current) { return failure }
        guard let version, let build, let codeDirectoryHash, let fileIdentity,
              current.version == version,
              current.build == build,
              current.codeDirectoryHash == codeDirectoryHash,
              !codeDirectoryHash.isEmpty else { return .artifactIdentityChanged }
        if requireSameFile, current.fileIdentity != fileIdentity {
            return .artifactIdentityChanged
        }
        return nil
    }

    /// Anchored at Apple, so a certificate chain we do not control cannot
    /// satisfy the check.
    ///
    /// Without this, validity is judged against the code's OWN designated
    /// requirement, which a self-signed bundle satisfies trivially — and the
    /// only other thing pinned here is the team identifier, a plain string in
    /// the certificate's subject OU that a self-signed certificate is free to
    /// claim. `anchor apple generic` is what makes that string mean something,
    /// because only Apple issues chains that satisfy it. `HelperCodeRequirement`
    /// already pins its nested engine this way; the updater has to match, or
    /// the SHA-512 from the feed is the only thing standing between a swapped
    /// app and an install.
    static let appleAnchoredRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString,
                                             [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    static func read(appURL: URL) -> BundleUpdateIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        // Validate every architecture in a universal app. Checking only the
        // host architecture could otherwise admit a tampered alternate slice.
        let checkAllArchitectures = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        // A requirement we could not build is treated as "refuse", never as
        // "skip the check" — the nil-requirement call is the weak one.
        let valid = appleAnchoredRequirement.map {
            SecStaticCodeCheckValidity(staticCode, checkAllArchitectures, $0) == errSecSuccess
        } ?? false
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any],
        let sealedInfo = values[kSecCodeInfoPList as String] as? [String: Any],
        let bundleID = sealedInfo[kCFBundleIdentifierKey as String] as? String,
        let version = sealedInfo["CFBundleShortVersionString"] as? String,
        let build = sealedInfo[kCFBundleVersionKey as String] as? String,
        let codeDirectoryHash = values[kSecCodeInfoUnique as String] as? Data,
        !codeDirectoryHash.isEmpty else { return nil }
        var status = stat()
        guard lstat(appURL.path, &status) == 0 else { return nil }
        return BundleUpdateIdentity(
            bundleID: bundleID,
            signingIdentifier: values[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            signatureValid: valid,
            version: version,
            build: build,
            codeDirectoryHash: codeDirectoryHash,
            fileIdentity: BundleFileIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            )
        )
    }
}

struct StagedElectronUpdate: Sendable {
    let targetURL: URL
    let candidateURL: URL
    let stagingDirectory: URL
    let stagingDirectoryIdentity: BundleFileIdentity
    let canonicalStagingDirectoryURL: URL
    let expectedIdentity: BundleUpdateIdentity
    let expectedCandidateIdentity: BundleUpdateIdentity?
    let descriptorVersion: String?

    init(
        targetURL: URL,
        candidateURL: URL,
        stagingDirectory: URL,
        stagingDirectoryIdentity: BundleFileIdentity,
        canonicalStagingDirectoryURL: URL,
        expectedIdentity: BundleUpdateIdentity,
        expectedCandidateIdentity: BundleUpdateIdentity? = nil,
        descriptorVersion: String? = nil
    ) {
        self.targetURL = targetURL
        self.candidateURL = candidateURL
        self.stagingDirectory = stagingDirectory
        self.stagingDirectoryIdentity = stagingDirectoryIdentity
        self.canonicalStagingDirectoryURL = canonicalStagingDirectoryURL
        self.expectedIdentity = expectedIdentity
        self.expectedCandidateIdentity = expectedCandidateIdentity
        self.descriptorVersion = descriptorVersion
    }

    func discard() {
        PrivateUpdateDirectory.discard(
            at: stagingDirectory,
            expectedIdentity: stagingDirectoryIdentity,
            expectedCanonicalURL: canonicalStagingDirectoryURL
        )
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
            // The path has not been pinned yet. Never recurse through a name
            // that another process could have replaced after mkdtemp.
            _ = rmdir(url.path)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
        return url
    }

    static func discard(
        at directoryURL: URL,
        expectedIdentity: BundleFileIdentity,
        expectedCanonicalURL: URL,
        afterOpeningPinnedRoot: ((URL) -> Void)? = nil
    ) {
        let sourceURL = directoryURL.standardizedFileURL
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL
                == expectedCanonicalURL.standardizedFileURL else { return }

        let parentURL = sourceURL.deletingLastPathComponent()
        let parentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { return }
        defer { close(parentFD) }

        let sourceName = sourceURL.lastPathComponent
        let quarantineName = ".Burrow Discard \(UUID().uuidString)"
        let quarantineURL = parentURL.appendingPathComponent(quarantineName, isDirectory: true)
        do {
            try moveExclusively(
                in: parentFD,
                from: sourceName,
                to: quarantineName
            )
        } catch {
            return
        }

        let rootFD = openat(parentFD, quarantineName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            try? moveExclusively(in: parentFD, from: quarantineName, to: sourceName)
            return
        }
        defer { close(rootFD) }

        var rootStatus = stat()
        guard fstat(rootFD, &rootStatus) == 0,
              directoryIdentity(from: rootStatus) == expectedIdentity else {
            // We captured a replacement tree, not Burrow's pinned staging
            // root. Put it back only if its original name is still vacant;
            // otherwise leave the quarantined tree intact for its owner.
            try? moveExclusively(in: parentFD, from: quarantineName, to: sourceName)
            return
        }

        afterOpeningPinnedRoot?(quarantineURL)

        // removefileat traverses relative to the verified, held root FD. KEEP_PARENT
        // leaves that exact directory in place until the parent-relative unlink
        // below; symlink entries are removed rather than followed.
        let recursive = UInt32(1 << 0)
        let keepParent = UInt32(1 << 1)
        let recursiveSlim = UInt32(1 << 11)
        let removalResult = ".".withCString {
            descriptorRelativeRemoveFile(
                rootFD,
                $0,
                nil,
                recursive | keepParent | recursiveSlim
            )
        }
        guard removalResult == 0,
              fstat(rootFD, &rootStatus) == 0,
              directoryIdentity(from: rootStatus) == expectedIdentity else { return }

        // Recheck the parent entry before unlinking. If the pathname was
        // replaced, AT_REMOVEDIR cannot remove a nonempty substitution; an
        // identity mismatch is left untouched even when it is empty.
        var namedStatus = stat()
        let namedIdentity: BundleFileIdentity? = quarantineName.withCString { name in
            guard fstatat(parentFD, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            return directoryIdentity(from: namedStatus)
        }
        guard namedIdentity == expectedIdentity else { return }
        _ = quarantineName.withCString { name in
            unlinkat(parentFD, name, AT_REMOVEDIR)
        }
    }

    static func directoryIdentity(at url: URL) -> BundleFileIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return directoryIdentity(from: status)
    }

    private static func directoryIdentity(from status: stat) -> BundleFileIdentity? {
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return BundleFileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    static func moveExclusively(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
    }

    private static func moveExclusively(
        in parentFD: Int32,
        from sourceName: String,
        to destinationName: String
    ) throws {
        let result = sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                renameatx_np(
                    parentFD,
                    sourcePath,
                    parentFD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
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

enum ElectronPostReplacementDecision: Equatable, Sendable {
    case accept
    case restore(
        installedIdentity: BundleUpdateIdentity?,
        backupIdentity: BundleUpdateIdentity,
        failure: UpdateFailure
    )
    case fail(UpdateFailure)
}

enum ElectronReplacementInstaller {
    /// Ceiling on an update archive we will keep and expand. Burrow's own
    /// releases are tens of megabytes, so 512 MB clears any plausible build
    /// while still refusing an archive whose only purpose is to fill the disk
    /// or explode under ditto.
    static let maximumArchiveBytes: Int64 = 512 * 1024 * 1024

    static func stagingDirectoryIdentity(at url: URL) -> BundleFileIdentity? {
        PrivateUpdateDirectory.directoryIdentity(at: url)
    }

    static func candidateLocationVerificationFailure(
        candidateURL: URL,
        stagingDirectory: URL,
        expectedStagingIdentity: BundleFileIdentity,
        expectedCanonicalStagingDirectory: URL
    ) -> UpdateFailure? {
        let lexicalRoot = stagingDirectory.standardizedFileURL
        let lexicalCandidate = candidateURL.standardizedFileURL
        guard stagingDirectoryIdentity(at: lexicalRoot) == expectedStagingIdentity else {
            return .verification(.artifactIdentityChanged)
        }

        let currentCanonicalRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalCandidate = lexicalCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard currentCanonicalRoot == expectedCanonicalStagingDirectory.standardizedFileURL,
              isStrictDescendant(canonicalCandidate, of: currentCanonicalRoot),
              isStrictDescendant(lexicalCandidate, of: lexicalRoot) else {
            return .verification(.artifactIdentityChanged)
        }

        // Walk the root-relative descriptor path with lstat. Canonical
        // containment alone would accept an intermediate symlink that happens
        // to resolve back inside the staging tree, while the installed
        // artifact would still be a mutable link rather than a pinned bundle.
        let relativeComponents = lexicalCandidate.pathComponents.dropFirst(lexicalRoot.pathComponents.count)
        var currentURL = lexicalRoot
        for component in relativeComponents {
            currentURL.appendPathComponent(component)
            guard stagingDirectoryIdentity(at: currentURL) != nil else {
                return .verification(.artifactIdentityChanged)
            }
        }
        return nil
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    static func stagingVerificationFailure(
        expectedIdentity: BundleUpdateIdentity,
        candidateIdentity: BundleUpdateIdentity,
        descriptorVersion: String
    ) -> UpdateFailure? {
        if let failure = expectedIdentity.artifactVerificationFailure(comparedWith: expectedIdentity) {
            return .verification(failure)
        }
        if let failure = expectedIdentity.verificationFailure(comparedWith: candidateIdentity) {
            return .verification(failure)
        }
        if let failure = candidateIdentity.artifactVerificationFailure(comparedWith: candidateIdentity) {
            return .verification(failure)
        }
        guard candidateIdentity.version == descriptorVersion else {
            return .verification(.artifactIdentityChanged)
        }
        return nil
    }

    static func boundaryVerificationFailure(
        for staged: StagedElectronUpdate,
        validateCandidateLocation: (StagedElectronUpdate) -> UpdateFailure? = {
            candidateLocationVerificationFailure(
                candidateURL: $0.candidateURL,
                stagingDirectory: $0.stagingDirectory,
                expectedStagingIdentity: $0.stagingDirectoryIdentity,
                expectedCanonicalStagingDirectory: $0.canonicalStagingDirectoryURL
            )
        },
        readIdentity: (URL) -> BundleUpdateIdentity? = { BundleUpdateIdentity.read(appURL: $0) }
    ) -> UpdateFailure? {
        if let failure = validateCandidateLocation(staged) { return failure }
        guard let targetIdentity = readIdentity(staged.targetURL) else {
            return .verification(.bundleIdentityChanged)
        }
        if let failure = staged.expectedIdentity.artifactVerificationFailure(comparedWith: targetIdentity) {
            return .verification(failure)
        }
        guard let expectedCandidateIdentity = staged.expectedCandidateIdentity,
              let descriptorVersion = staged.descriptorVersion,
              expectedCandidateIdentity.version == descriptorVersion else {
            return .verification(.artifactIdentityChanged)
        }
        guard let candidateIdentity = readIdentity(staged.candidateURL) else {
            return .verification(.invalidSignature)
        }
        if let failure = expectedCandidateIdentity.artifactVerificationFailure(comparedWith: candidateIdentity) {
            return .verification(failure)
        }
        return nil
    }

    static func postReplacementDecision(
        for staged: StagedElectronUpdate,
        backupURL: URL,
        readIdentity: (URL) -> BundleUpdateIdentity? = { BundleUpdateIdentity.read(appURL: $0) }
    ) -> ElectronPostReplacementDecision {
        // Read both moved artifacts even if the installed candidate is bad.
        // A valid backup is the only safe recovery path, and selecting it
        // based on existence alone would let a path swap drive rollback.
        let installedIdentity = readIdentity(staged.targetURL)
        let backupIdentity = readIdentity(backupURL)

        let installedFailure: UpdateFailure?
        if let expectedCandidateIdentity = staged.expectedCandidateIdentity,
           let descriptorVersion = staged.descriptorVersion,
           expectedCandidateIdentity.version == descriptorVersion,
           let installedIdentity {
            installedFailure = expectedCandidateIdentity
                .artifactVerificationFailure(comparedWith: installedIdentity)
                .map(UpdateFailure.verification)
        } else {
            installedFailure = .verification(.artifactIdentityChanged)
        }

        guard let backupIdentity,
              isEligibleRollbackIdentity(backupIdentity, for: staged) else {
            return .fail(recoveryFailure())
        }

        let backupIsPinnedTarget = staged.expectedIdentity
            .artifactVerificationFailure(comparedWith: backupIdentity) == nil
        if installedFailure == nil, backupIsPinnedTarget {
            return .accept
        }

        return .restore(
            installedIdentity: installedIdentity,
            backupIdentity: backupIdentity,
            failure: installedFailure ?? .verification(.artifactIdentityChanged)
        )
    }

    static func postReplacementVerificationFailure(
        for staged: StagedElectronUpdate,
        backupURL: URL,
        readIdentity: (URL) -> BundleUpdateIdentity? = { BundleUpdateIdentity.read(appURL: $0) }
    ) -> UpdateFailure? {
        switch postReplacementDecision(for: staged, backupURL: backupURL, readIdentity: readIdentity) {
        case .accept:
            return nil
        case let .restore(_, _, failure), let .fail(failure):
            return failure
        }
    }

    static func replacePreservingBackup(
        targetURL: URL,
        candidateURL: URL,
        backupName: String,
        fileManager: FileManager = .default
    ) throws {
        _ = try fileManager.replaceItemAt(
            targetURL,
            withItemAt: candidateURL,
            backupItemName: backupName,
            options: [.withoutDeletingBackupItem]
        )
    }

    static func removePreservedBackup(
        at backupURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.removeItem(at: backupURL)
    }

    static func moveItemExclusively(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try PrivateUpdateDirectory.moveExclusively(from: sourceURL, to: destinationURL)
    }

    static func pathEntryExists(at url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    static func restoreVerifiedBackup(
        for staged: StagedElectronUpdate,
        backupURL: URL,
        capturedInstalledIdentity: BundleUpdateIdentity?,
        capturedBackupIdentity: BundleUpdateIdentity,
        replaceItem: (URL, URL, String) throws -> Void = { targetURL, replacementURL, backupName in
            try replacePreservingBackup(
                targetURL: targetURL,
                candidateURL: replacementURL,
                backupName: backupName
            )
        },
        moveItemExclusively: (URL, URL) throws -> Void = { sourceURL, destinationURL in
            try moveItemExclusively(from: sourceURL, to: destinationURL)
        },
        pathExists: (URL) -> Bool = { pathEntryExists(at: $0) },
        readIdentity: (URL) -> BundleUpdateIdentity? = { BundleUpdateIdentity.read(appURL: $0) }
    ) -> UpdateFailure? {
        guard isEligibleRollbackIdentity(capturedBackupIdentity, for: staged) else {
            return recoveryFailure()
        }

        // Revalidate both paths immediately before consuming either one. The
        // decision was made earlier, so a modal event loop or another updater
        // could otherwise swap the target or backup before rollback begins.
        let currentInstalledIdentity = readIdentity(staged.targetURL)
        let currentBackupIdentity = readIdentity(backupURL)
        guard currentInstalledIdentity == capturedInstalledIdentity,
              currentBackupIdentity == capturedBackupIdentity else {
            return recoveryFailure()
        }

        // `replaceItemAt` requires the target to exist. If the moved-in app
        // vanished entirely, use an exclusive rename so a target appearing
        // concurrently is never overwritten by the recovery operation.
        if capturedInstalledIdentity == nil, !pathExists(staged.targetURL) {
            do {
                try moveItemExclusively(backupURL, staged.targetURL)
            } catch {
                return recoveryFailure(error)
            }
            guard readIdentity(staged.targetURL) == capturedBackupIdentity else {
                return recoveryFailure()
            }
            return nil
        }

        let displacedName = ".Burrow Displaced Candidate \(UUID().uuidString).app"
        let displacedURL = staged.targetURL.deletingLastPathComponent().appendingPathComponent(displacedName)
        var replacementError: Error?
        do {
            try replaceItem(staged.targetURL, backupURL, displacedName)
        } catch {
            replacementError = error
        }

        // Verify both sides of the replacement before deleting anything. A
        // newer app can race into the target after the precheck and will then
        // be the item preserved at `displacedURL`.
        let restoredIdentity = readIdentity(staged.targetURL)
        let displacedIdentity = readIdentity(displacedURL)
        if restoredIdentity == capturedBackupIdentity,
           displacedIdentity == capturedInstalledIdentity {
            if capturedInstalledIdentity != nil {
                try? removePreservedBackup(at: displacedURL)
            }
            return nil
        }

        if let capturedInstalledIdentity,
           displacedIdentity == capturedInstalledIdentity,
           isPinnedExpectedCandidate(capturedInstalledIdentity, for: staged),
           replaceAndVerifyPreservedArtifact(
               staged: staged,
               sourceURL: displacedURL,
               desiredIdentity: capturedInstalledIdentity,
               capturedCurrentTargetIdentity: restoredIdentity,
               replaceItem: replaceItem,
               readIdentity: readIdentity
           ) {
            return recoveryFailure(replacementError)
        }

        if let displacedIdentity,
           shouldPreferDisplacedIdentity(
               displacedIdentity,
               over: capturedBackupIdentity,
               for: staged
           ),
           replaceAndVerifyPreservedArtifact(
               staged: staged,
               sourceURL: displacedURL,
               desiredIdentity: displacedIdentity,
               capturedCurrentTargetIdentity: restoredIdentity,
               replaceItem: replaceItem,
               readIdentity: readIdentity
           ) {
            return nil
        }

        return recoveryFailure(replacementError)
    }

    private static func replaceAndVerifyPreservedArtifact(
        staged: StagedElectronUpdate,
        sourceURL: URL,
        desiredIdentity: BundleUpdateIdentity,
        capturedCurrentTargetIdentity: BundleUpdateIdentity?,
        replaceItem: (URL, URL, String) throws -> Void,
        readIdentity: (URL) -> BundleUpdateIdentity?
    ) -> Bool {
        let currentTargetIdentity = readIdentity(staged.targetURL)
        let currentSourceIdentity = readIdentity(sourceURL)
        guard currentTargetIdentity == capturedCurrentTargetIdentity,
              currentSourceIdentity == desiredIdentity else { return false }

        let quarantineName = ".Burrow Failed Rollback \(UUID().uuidString).app"
        let quarantineURL = staged.targetURL.deletingLastPathComponent().appendingPathComponent(quarantineName)
        do {
            try replaceItem(staged.targetURL, sourceURL, quarantineName)
        } catch {
            return false
        }
        let installedIdentity = readIdentity(staged.targetURL)
        let quarantinedIdentity = readIdentity(quarantineURL)
        guard installedIdentity == desiredIdentity,
              quarantinedIdentity == capturedCurrentTargetIdentity else { return false }
        if capturedCurrentTargetIdentity != nil {
            try? removePreservedBackup(at: quarantineURL)
        }
        return true
    }

    private static func isPinnedExpectedCandidate(
        _ identity: BundleUpdateIdentity,
        for staged: StagedElectronUpdate
    ) -> Bool {
        guard let expectedCandidateIdentity = staged.expectedCandidateIdentity,
              expectedCandidateIdentity.version == staged.descriptorVersion else { return false }
        return expectedCandidateIdentity.artifactVerificationFailure(comparedWith: identity) == nil
    }

    private static func shouldPreferDisplacedIdentity(
        _ displacedIdentity: BundleUpdateIdentity,
        over restoredIdentity: BundleUpdateIdentity,
        for staged: StagedElectronUpdate
    ) -> Bool {
        guard displacedIdentity != restoredIdentity,
              isEligibleRollbackIdentity(displacedIdentity, for: staged) else { return false }
        return isProvablyNotOlder(displacedIdentity, than: restoredIdentity)
    }

    private static func isEligibleRollbackIdentity(
        _ backupIdentity: BundleUpdateIdentity,
        for staged: StagedElectronUpdate
    ) -> Bool {
        guard staged.expectedIdentity.verificationFailure(comparedWith: backupIdentity) == nil,
              backupIdentity.artifactVerificationFailure(comparedWith: backupIdentity) == nil else {
            return false
        }
        if staged.expectedIdentity.artifactVerificationFailure(comparedWith: backupIdentity) == nil {
            return true
        }
        guard let expectedCandidateIdentity = staged.expectedCandidateIdentity else { return false }
        return isProvablyNotOlder(backupIdentity, than: expectedCandidateIdentity)
    }

    private static func isProvablyNotOlder(
        _ backupIdentity: BundleUpdateIdentity,
        than candidateIdentity: BundleUpdateIdentity
    ) -> Bool {
        guard let backupVersion = backupIdentity.version,
              let backupBuild = backupIdentity.build,
              let candidateVersion = candidateIdentity.version,
              let candidateBuild = candidateIdentity.build,
              let versionComparison = semanticVersionComparison(backupVersion, candidateVersion)
                ?? numericVersionComparison(backupVersion, candidateVersion) else {
            return false
        }
        if versionComparison == .orderedDescending { return true }
        if versionComparison == .orderedAscending { return false }
        guard let buildComparison = numericVersionComparison(backupBuild, candidateBuild) else { return false }
        if buildComparison == .orderedDescending { return true }
        if buildComparison == .orderedAscending { return false }
        // Equal advertised versions are only ordered safely when the sealed
        // code identity is also identical. An arbitrary same-version build
        // is not evidence that it is at least as new.
        return backupIdentity.codeDirectoryHash == candidateIdentity.codeDirectoryHash
    }

    private enum SemanticVersionIdentifier: Equatable {
        case numeric(UInt64)
        case text(String)
    }

    private struct SemanticVersion {
        let core: [UInt64]
        let prerelease: [SemanticVersionIdentifier]?
    }

    private static func semanticVersionComparison(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult? {
        guard let lhsVersion = parseSemanticVersion(lhs),
              let rhsVersion = parseSemanticVersion(rhs) else { return nil }
        for index in 0..<3 where lhsVersion.core[index] != rhsVersion.core[index] {
            return lhsVersion.core[index] < rhsVersion.core[index] ? .orderedAscending : .orderedDescending
        }
        switch (lhsVersion.prerelease, rhsVersion.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, .some):
            return .orderedDescending
        case (.some, nil):
            return .orderedAscending
        case let (.some(lhsIdentifiers), .some(rhsIdentifiers)):
            for index in 0..<min(lhsIdentifiers.count, rhsIdentifiers.count) {
                let comparison: ComparisonResult
                switch (lhsIdentifiers[index], rhsIdentifiers[index]) {
                case let (.numeric(lhsNumber), .numeric(rhsNumber)):
                    comparison = lhsNumber == rhsNumber
                        ? .orderedSame
                        : (lhsNumber < rhsNumber ? .orderedAscending : .orderedDescending)
                case (.numeric, .text):
                    comparison = .orderedAscending
                case (.text, .numeric):
                    comparison = .orderedDescending
                case let (.text(lhsText), .text(rhsText)):
                    comparison = lhsText == rhsText
                        ? .orderedSame
                        : (lhsText < rhsText ? .orderedAscending : .orderedDescending)
                }
                if comparison != .orderedSame { return comparison }
            }
            if lhsIdentifiers.count == rhsIdentifiers.count { return .orderedSame }
            return lhsIdentifiers.count < rhsIdentifiers.count ? .orderedAscending : .orderedDescending
        }
    }

    private static func parseSemanticVersion(_ rawValue: String) -> SemanticVersion? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let withoutBuildMetadata = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !withoutBuildMetadata[0].isEmpty,
              withoutBuildMetadata.count == 1 || !withoutBuildMetadata[1].isEmpty else { return nil }
        let versionAndPrerelease = withoutBuildMetadata[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let coreParts = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count == 3 else { return nil }
        var core: [UInt64] = []
        for part in coreParts {
            guard !part.isEmpty,
                  (part.count == 1 || part.first != "0"),
                  let number = UInt64(part) else { return nil }
            core.append(number)
        }

        var prerelease: [SemanticVersionIdentifier]?
        if versionAndPrerelease.count == 2 {
            let parts = versionAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            var identifiers: [SemanticVersionIdentifier] = []
            for part in parts {
                guard !part.isEmpty,
                      part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                    return nil
                }
                if part.allSatisfy(\.isNumber) {
                    guard (part.count == 1 || part.first != "0"), let number = UInt64(part) else { return nil }
                    identifiers.append(.numeric(number))
                } else {
                    identifiers.append(.text(String(part)))
                }
            }
            prerelease = identifiers
        }
        return SemanticVersion(core: core, prerelease: prerelease)
    }

    private static func numericVersionComparison(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult? {
        func components(_ value: String) -> [UInt64]? {
            var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
            let rawComponents = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !rawComponents.isEmpty else { return nil }
            var result: [UInt64] = []
            for component in rawComponents {
                guard !component.isEmpty, let number = UInt64(component) else { return nil }
                result.append(number)
            }
            return result
        }
        guard let lhsComponents = components(lhs), let rhsComponents = components(rhs) else { return nil }
        for index in 0..<max(lhsComponents.count, rhsComponents.count) {
            let lhsComponent = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsComponent = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsComponent < rhsComponent { return .orderedAscending }
            if lhsComponent > rhsComponent { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func recoveryFailure(_ error: Error? = nil) -> UpdateFailure {
        var message = NSLocalizedString(
            "Burrow could not verify or safely restore the previous app after replacement. Reinstall it from its developer before retrying.",
            comment: ""
        )
        if let error { message += " \(error.localizedDescription)" }
        return .installation(message)
    }

    static func stage(
        appPath: String,
        descriptor: ElectronUpdateDescriptor
    ) async -> ElectronStageOutcome {
        let targetURL = URL(fileURLWithPath: appPath, isDirectory: true)
        guard let expectedIdentity = BundleUpdateIdentity.read(appURL: targetURL),
              expectedIdentity.artifactVerificationFailure(comparedWith: expectedIdentity) == nil else {
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
        guard let stagingIdentity = stagingDirectoryIdentity(at: root) else {
            _ = rmdir(root.path)
            return .failure(.verification(.artifactIdentityChanged))
        }
        let canonicalStagingDirectory = root.resolvingSymlinksInPath().standardizedFileURL
        let discardRoot = {
            PrivateUpdateDirectory.discard(
                at: root,
                expectedIdentity: stagingIdentity,
                expectedCanonicalURL: canonicalStagingDirectory
            )
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
            // Refuse an implausible archive BEFORE it is kept, hashed, or —
            // the part that actually matters — handed to ditto, where a small
            // zip expands into an arbitrarily large tree. URLSession has
            // already written the body by the time this returns, so this does
            // not bound what transits the network; it bounds what we retain
            // and what we agree to expand. Burrow's own archives are tens of
            // megabytes, so the ceiling is far above any real release.
            if http.expectedContentLength > Self.maximumArchiveBytes {
                throw UpdateFailure.invalidResponse
            }
            let downloadedBytes = (try? FileManager.default.attributesOfItem(
                atPath: temporaryDownload.path)[.size] as? Int64) ?? nil
            if let downloadedBytes, downloadedBytes > Self.maximumArchiveBytes {
                throw UpdateFailure.invalidResponse
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
            guard let candidate = firstApplication(in: extracted) else {
                throw UpdateFailure.verification(.invalidSignature)
            }
            if let failure = candidateLocationVerificationFailure(
                candidateURL: candidate,
                stagingDirectory: root,
                expectedStagingIdentity: stagingIdentity,
                expectedCanonicalStagingDirectory: canonicalStagingDirectory
            ) {
                throw failure
            }
            guard let candidateIdentity = BundleUpdateIdentity.read(appURL: candidate) else {
                throw UpdateFailure.verification(.invalidSignature)
            }
            if let failure = stagingVerificationFailure(
                expectedIdentity: expectedIdentity,
                candidateIdentity: candidateIdentity,
                descriptorVersion: descriptor.version
            ) {
                throw failure
            }
            return .ready(StagedElectronUpdate(
                targetURL: targetURL,
                candidateURL: candidate,
                stagingDirectory: root,
                stagingDirectoryIdentity: stagingIdentity,
                canonicalStagingDirectoryURL: canonicalStagingDirectory,
                expectedIdentity: expectedIdentity,
                expectedCandidateIdentity: candidateIdentity,
                descriptorVersion: descriptor.version
            ))
        } catch let failure as UpdateFailure {
            discardRoot()
            return .failure(failure)
        } catch let error as URLError {
            discardRoot()
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
            discardRoot()
            return .failure(.installation(error.localizedDescription))
        }
    }

    @MainActor
    static func install(_ staged: StagedElectronUpdate) async -> ElectronInstallOutcome {
        defer { staged.discard() }
        if let failure = boundaryVerificationFailure(for: staged) {
            return .failure(failure)
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

        let backupName = ".Burrow Update Backup \(UUID().uuidString).app"
        let backupURL = staged.targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
        // No suspension is allowed between this exact target/candidate check
        // and replacement. Post-replace verification below also pins the
        // moved inodes, closing a path-swap race in this final check/use gap.
        if let failure = boundaryVerificationFailure(for: staged) {
            return .failure(failure)
        }
        do {
            try replacePreservingBackup(
                targetURL: staged.targetURL,
                candidateURL: staged.candidateURL,
                backupName: backupName
            )
            switch postReplacementDecision(for: staged, backupURL: backupURL) {
            case .accept:
                try? removePreservedBackup(at: backupURL)
            case let .restore(installedIdentity, backupIdentity, failure):
                if let recoveryFailure = restoreVerifiedBackup(
                    for: staged,
                    backupURL: backupURL,
                    capturedInstalledIdentity: installedIdentity,
                    capturedBackupIdentity: backupIdentity
                ) {
                    return .failure(recoveryFailure)
                }
                return .failure(failure)
            case let .fail(failure):
                return .failure(failure)
            }
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
