//
//  HelperCodeRequirement.swift
//  Burrow / BurrowHelper (shared)
//
//  Who may talk to the root daemon at all.
//
//  Authorization (HelperAuthorization) answers "may this operation run".
//  This answers the question that comes first: "is the process on the other
//  end of this XPC connection actually Burrow". Both are required, and the
//  order matters — without this check, any local process could open the Mach
//  service and drive the authentication prompt, phishing the user for
//  administrator credentials behind a dialog the system itself renders and
//  that therefore looks entirely legitimate.
//
//  ── Identifying the peer correctly ──────────────────────────────────────
//  The requirement built here is handed to
//  `NSXPCListener.setConnectionCodeSigningRequirement`, so the SYSTEM
//  evaluates it against the connecting peer before the delegate is ever
//  called. That matters more than it looks:
//
//  The obvious hand-rolled check — read `connection.processIdentifier`, look
//  the process up, verify its signature — is the classic vulnerable pattern.
//  A PID can be recycled between being read and being checked, and the
//  standard exploit hands the helper the PID of a legitimate app and then
//  races a hostile process into that slot. Doing it properly means the audit
//  token, and reaching an NSXPCConnection's audit token means private API,
//  which is not a dependency worth taking inside a root daemon.
//
//  The macOS 13 requirement API sidesteps both problems: it is supported, and
//  the evaluation happens in the kernel against the real peer, with no window
//  between check and use.
//
//  ── The team is discovered, not compiled in ─────────────────────────────
//  The requirement is assembled at RUNTIME from the daemon's own signing
//  information: the helper asks what team signed IT, and demands the caller be
//  the Burrow app signed by that same team. Nothing here is baked in, so the
//  check keeps working across certificate renewals and an ad-hoc local build
//  needs no special case.
//
//  The release workflow does pin the expected team as `EXPECTED_TEAM_ID` so a
//  misconfigured signing identity fails the build rather than shipping. That is
//  a build-time assertion about which certificate we meant to use; a team ID is
//  public (it is in every signature we ship) and is not a secret. This file
//  still learns it at runtime, and must keep doing so — hardcoding it here
//  would break the ad-hoc development path and add a second place to update.
//

import Foundation
import Security
import Darwin

enum HelperCodeRequirement {

    /// A syntactically valid requirement that no code can satisfy, used
    /// whenever a safe requirement cannot be built.
    ///
    /// It is deliberately not the empty string: an empty requirement fails to
    /// PARSE, and several Security APIs treat a parse failure as "no
    /// requirement given", which is the exact opposite of failing closed. This
    /// one parses fine and simply matches nothing, because no bundle
    /// identifier may contain a space.
    static let unsatisfiable = #"identifier "dev.caezium.Burrow.no such caller""#

    // MARK: - Input validation
    //
    // The requirement string is a small language parsed by the Security
    // framework, and identifiers are interpolated into it. A value containing
    // a quote could close the literal early and append its own clause —
    // `identifier "x" or anchor apple generic` would admit every Apple-signed
    // process on the machine.
    //
    // Hostile values are REFUSED rather than escaped. A legitimate bundle
    // identifier or team ID is drawn from a small alphabet, so rejecting
    // anything outside it costs nothing and removes a whole class of parser
    // subtleties — there is no "correctly escaped" case left to get wrong.

    /// The characters a real bundle identifier or team ID is built from.
    private static let permitted = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")

    /// The value if it can ride inertly inside a requirement string, else nil.
    static func validated(identifier: String) -> String? {
        guard !identifier.isEmpty, identifier.count <= 255 else { return nil }
        guard identifier.unicodeScalars.allSatisfy({ permitted.contains($0) }) else { return nil }
        return identifier
    }

    // MARK: - Building the requirement

    /// The designated requirement a caller must satisfy.
    ///
    /// With a team ID, three clauses are pinned and every one is mandatory:
    ///   * `identifier` — this exact bundle, not merely something of ours;
    ///   * `anchor apple generic` — a chain terminating at Apple, so a
    ///     self-signed build cannot claim the identifier;
    ///   * `certificate leaf[subject.OU]` — signed by the same team as the
    ///     helper, so another developer's notarized app cannot impersonate us.
    ///
    /// Without a team ID (a local ad-hoc Debug build) it falls back to the
    /// identifier alone so development works. That is explicitly NOT
    /// distribution grade, and `isDistributionGrade` is what the release gate
    /// checks so an ad-hoc helper can never ship.
    static func string(bundleID: String, teamID: String?) -> String {
        guard let identifier = validated(identifier: bundleID) else { return unsatisfiable }

        guard let teamID, !teamID.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"identifier "\#(identifier)""#
        }
        guard let team = validated(identifier: teamID) else { return unsatisfiable }

        return #"identifier "\#(identifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }

    /// Whether a requirement built from this team is strong enough to ship.
    /// An ad-hoc helper has no team, so it can be impersonated by any local
    /// build that claims the identifier — fine for development, never for a
    /// release.
    static func isDistributionGrade(teamID: String?) -> Bool {
        guard let teamID, !teamID.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return validated(identifier: teamID) != nil
    }

    // MARK: - System witnesses

    /// The team that signed the given code, or nil when it is unsigned or
    /// ad-hoc signed. Used by the daemon to learn its OWN team, so the
    /// requirement never needs a hardcoded value.
    static func teamIdentifier(of code: SecCode?) -> String? {
        guard let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return teamIdentifier(ofStatic: staticCode)
    }

    static func teamIdentifier(ofStatic staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return team.flatMap { validated(identifier: $0) }
    }

    /// The team that signed the currently running process.
    static func selfTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return teamIdentifier(of: code)
    }

    /// A requirement matching any code signed by `teamID` with an Apple-issued
    /// chain, without pinning a bundle identifier.
    ///
    /// Used for the nested ENGINE binary, which carries its own identifier but
    /// is re-signed with our identity by the release pipeline. Returns nil
    /// when a safe requirement can't be built, and callers treat that as
    /// "refuse to run" rather than "skip the check".
    static func sameTeam(teamID: String) -> String? {
        guard let team = validated(identifier: teamID) else { return nil }
        return #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }
}

/// A private copy of the app whose resource seal has been verified in place.
///
/// `SecStaticCodeCheckValidity` accepts a path, and `Process` also launches a
/// path. Validating the installed bundle and later launching from it leaves a
/// rename window between those two operations. The helper closes that window
/// by cloning the bundle beneath a fresh 0700 root-owned directory, validating
/// that clone, and retaining it until the child exits. No unprivileged process
/// can replace anything below `rootURL`, so the validated bytes and launched
/// bytes are the same filesystem objects.
final class HelperExecutableSnapshot {
    enum SnapshotError: Error {
        case invalidParent
        case cannotCreateRoot(Int32)
        case copyFailed(Int32)
        case verificationFailed
    }

    let rootURL: URL
    let appBundleURL: URL
    let executableURL: URL

    private let lock = NSLock()
    private var removed = false

    private init(rootURL: URL, appBundleURL: URL, executableURL: URL) {
        self.rootURL = rootURL
        self.appBundleURL = appBundleURL
        self.executableURL = executableURL
    }

    /// The verifier is injectable only so unit tests can exercise the
    /// filesystem boundary with a tiny fixture. The daemon supplies the real
    /// Security-framework resource-seal check.
    static func prepare(appBundleURL source: URL,
                        parentDirectory: URL = URL(fileURLWithPath: "/private/var/tmp",
                                                   isDirectory: true),
                        expectedOwner: uid_t = 0,
                        expectedBundleID: String,
                        expectedBuild: String,
                        verify: (URL) -> Bool) throws -> HelperExecutableSnapshot {
        guard let canonicalParent = canonicalPath(parentDirectory.path) else {
            throw SnapshotError.invalidParent
        }
        let parent = URL(fileURLWithPath: canonicalParent, isDirectory: true)
        var parentStat = stat()
        guard lstat(parent.path, &parentStat) == 0,
              (parentStat.st_mode & S_IFMT) == S_IFDIR,
              parentStat.st_uid == expectedOwner else {
            throw SnapshotError.invalidParent
        }
        // A writable parent is safe only when sticky: /private/var/tmp lets a
        // user create their own entries but not replace a root-owned one.
        let writable = parentStat.st_mode & 0o022 != 0
        guard !writable || parentStat.st_mode & S_ISVTX != 0 else {
            throw SnapshotError.invalidParent
        }

        var template = Array((parent.path + "/dev.caezium.burrow.engine.XXXXXX").utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { bytes in
            guard let path = mkdtemp(bytes.baseAddress) else { return nil }
            return String(cString: path)
        }
        guard let rootPath = created else { throw SnapshotError.cannotCreateRoot(errno) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        var keep = false
        defer {
            if !keep { try? FileManager.default.removeItem(at: root) }
        }
        guard chmod(rootPath, 0o700) == 0 else {
            throw SnapshotError.cannotCreateRoot(errno)
        }

        let copiedApp = root.appendingPathComponent("Burrow.app", isDirectory: true)
        let cloneFlags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        var copyResult = copyfile(source.path, copiedApp.path, nil, cloneFlags)
        if copyResult != 0 {
            let firstError = errno
            try? FileManager.default.removeItem(at: copiedApp)
            let fallbackFlags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE)
            copyResult = copyfile(source.path, copiedApp.path, nil, fallbackFlags)
            guard copyResult == 0 else {
                throw SnapshotError.copyFailed(errno == 0 ? firstError : errno)
            }
        }

        let contents = copiedApp.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let engineDirectory = resources.appendingPathComponent("engine", isDirectory: true)
        let executable = engineDirectory.appendingPathComponent("mole", isDirectory: false)
        guard [copiedApp, contents, resources, engineDirectory].allSatisfy(isRealDirectory),
              isExecutableRegularFile(executable),
              verify(copiedApp),
              matchesSealedMetadata(at: copiedApp,
                                    expectedBundleID: expectedBundleID,
                                    expectedBuild: expectedBuild) else {
            throw SnapshotError.verificationFailed
        }

        keep = true
        return HelperExecutableSnapshot(rootURL: root, appBundleURL: copiedApp,
                                        executableURL: executable)
    }

    func remove() {
        lock.lock()
        guard !removed else { lock.unlock(); return }
        removed = true
        lock.unlock()
        try? FileManager.default.removeItem(at: rootURL)
    }

    deinit { remove() }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && (value.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isExecutableRegularFile(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 &&
            (value.st_mode & S_IFMT) == S_IFREG && value.st_mode & 0o111 != 0
    }

    static func matchesSealedMetadata(at appBundleURL: URL,
                                      expectedBundleID: String,
                                      expectedBuild: String) -> Bool {
        let infoURL = appBundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let value = try? PropertyListSerialization.propertyList(from: data,
                                                                       format: nil),
              let info = value as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == expectedBundleID &&
            info["CFBundleVersion"] as? String == expectedBuild
    }
}
