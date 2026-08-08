//
//  PrivilegedExecution.swift
//  Burrow
//
//  Values crossing Burrow's administrator boundary are resolved and pinned
//  while the app is still running as the invoking user.  The privileged
//  shell then revalidates the same filesystem identities immediately before
//  execution.  A path string by itself is never authority to run code as
//  root.
//

import Foundation
import Darwin

struct InvokingUserIdentity: Sendable, Equatable {
    struct Account: Sendable, Equatable {
        let uid: uid_t
        let name: String
        let home: String
    }

    enum ResolutionError: LocalizedError, Equatable {
        case rootProcess
        case missingAccount(uid_t)
        case mismatchedAccount(expected: uid_t, actual: uid_t)
        case mismatchedHomeOwner(expected: uid_t, actual: uid_t)
        case invalidName
        case invalidHome

        var errorDescription: String? {
            switch self {
            case .rootProcess:
                return "Burrow must be launched by a signed-in user, not root."
            case .missingAccount(let uid):
                return "The account for user id \(uid) no longer exists."
            case .mismatchedAccount:
                return "The invoking account changed before authorization."
            case .mismatchedHomeOwner:
                return "The invoking account does not own its resolved home directory."
            case .invalidName:
                return "The invoking account name is invalid."
            case .invalidHome:
                return "The invoking account home directory is invalid."
            }
        }
    }

    let uid: uid_t
    let username: String
    /// `realpath(3)` result.  This is intentionally captured before the
    /// administrator dialog; root's HOME (/var/root) is never consulted.
    let canonicalHome: String

    static func current() throws -> Self {
        let invokingUID = getuid()
        guard invokingUID != 0 else { throw ResolutionError.rootProcess }
        guard let pwd = getpwuid(invokingUID) else {
            throw ResolutionError.missingAccount(invokingUID)
        }
        let account = Account(uid: pwd.pointee.pw_uid,
                              name: String(cString: pwd.pointee.pw_name),
                              home: String(cString: pwd.pointee.pw_dir))
        return try resolve(invokingUID: invokingUID, accounts: [account])
    }

    /// Deterministic resolver used by tests to cover missing users and hosts
    /// with several signed-in/local accounts.  Selection is by the process's
    /// numeric uid, never by a mutable USER/SUDO_USER environment variable.
    static func resolve(invokingUID: uid_t,
                        accounts: [Account],
                        canonicalize: (String) -> String? = Self.canonicalPath) throws -> Self {
        guard invokingUID != 0 else { throw ResolutionError.rootProcess }
        guard let account = accounts.first(where: { $0.uid == invokingUID }) else {
            throw ResolutionError.missingAccount(invokingUID)
        }
        guard account.uid == invokingUID else {
            throw ResolutionError.mismatchedAccount(expected: invokingUID, actual: account.uid)
        }
        guard account.name != "root", !account.name.isEmpty,
              !account.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ResolutionError.invalidName
        }
        guard account.home.hasPrefix("/"),
              !account.home.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let home = canonicalize(account.home), home.hasPrefix("/"), home != "/var/root" else {
            throw ResolutionError.invalidHome
        }
        var st = stat()
        guard lstat(home, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw ResolutionError.invalidHome
        }
        guard st.st_uid == invokingUID else {
            throw ResolutionError.mismatchedHomeOwner(expected: invokingUID, actual: st.st_uid)
        }
        return Self(uid: invokingUID, username: account.name, canonicalHome: home)
    }

    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// An lstat identity.  Matching device+inode+type means a symlink swap or
/// replacement cannot silently turn a reviewed/validated object into another
/// one while the administrator sheet is open.
struct PinnedFileIdentity: Sendable, Equatable, Codable {
    enum IdentityError: LocalizedError {
        case missing(String)
        case symlink(String)
        case wrongType(String)
        case mutableComponent(String)

        var errorDescription: String? {
            switch self {
            case .missing(let p): return "A required path no longer exists: \(p)"
            case .symlink(let p): return "A symbolic link is not allowed here: \(p)"
            case .wrongType(let p): return "A required path has the wrong type: \(p)"
            case .mutableComponent(let p): return "A privileged executable can be replaced by the current user: \(p)"
            }
        }
    }

    let path: String
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt16

    var isDirectory: Bool { (mode_t(mode) & S_IFMT) == S_IFDIR }
    var isRegular: Bool { (mode_t(mode) & S_IFMT) == S_IFREG }
    var isSymbolicLink: Bool { (mode_t(mode) & S_IFMT) == S_IFLNK }

    static func capture(_ path: String, rejectSymlink: Bool = true) throws -> Self {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw IdentityError.missing(path) }
        if rejectSymlink, (st.st_mode & S_IFMT) == S_IFLNK { throw IdentityError.symlink(path) }
        return Self(path: path, device: UInt64(st.st_dev), inode: UInt64(st.st_ino),
                    owner: UInt32(st.st_uid), mode: UInt16(st.st_mode))
    }

    func matchesCurrent() -> Bool {
        // A reviewed descendant may itself be a symlink. Capture the link's
        // identity without following it; a regular-file-to-symlink swap still
        // fails because the inode and complete mode are pinned.
        guard let current = try? Self.capture(path, rejectSymlink: false) else { return false }
        return current.device == device && current.inode == inode &&
            current.owner == owner && current.mode == mode
    }

    /// BSD stat's `%p` is the complete mode in octal (for example 100755).
    var shellStatToken: String {
        "\(device):\(inode):\(owner):\(String(mode, radix: 8))"
    }
}

struct ValidatedElevatedCommand: Sendable, Equatable {
    enum ValidationError: LocalizedError {
        case nonCanonicalExecutable
        case executableNotRegular
        case executableNotRootOwned
        case executableMutable(String)
        case unsignedBundle

        var errorDescription: String? {
            switch self {
            case .nonCanonicalExecutable: return "The privileged executable path is not canonical."
            case .executableNotRegular: return "The privileged executable is not a regular file."
            case .executableNotRootOwned: return "The privileged executable is not owned by root."
            case .executableMutable(let p): return "The privileged executable can be replaced at \(p)."
            case .unsignedBundle: return "The bundled cleanup engine could not be verified."
            }
        }
    }

    let executable: PinnedFileIdentity
    /// Every ancestor, including `/`, pinned and proven root-owned and not
    /// group/world-writable.  Once this holds, an unprivileged process cannot
    /// win a check/exec rename race.
    let components: [PinnedFileIdentity]
    let invokingUser: InvokingUserIdentity
    let signedBundlePath: String?

    static func prepare(executable rawPath: String,
                        invokingUser: InvokingUserIdentity,
                        requireCurrentBundle: Bool,
                        requiredOwner: uid_t = 0) throws -> Self {
        guard let canonical = InvokingUserIdentity.canonicalPath(rawPath), canonical == rawPath else {
            throw ValidationError.nonCanonicalExecutable
        }
        let executable = try PinnedFileIdentity.capture(canonical)
        guard executable.isRegular else { throw ValidationError.executableNotRegular }
        guard executable.owner == requiredOwner else { throw ValidationError.executableNotRootOwned }

        let url = URL(fileURLWithPath: canonical)
        var componentPaths = ["/"]
        var cursor = ""
        for component in url.pathComponents.dropFirst().dropLast() {
            cursor += "/" + component
            componentPaths.append(cursor)
        }
        var components: [PinnedFileIdentity] = []
        for path in componentPaths {
            let identity = try PinnedFileIdentity.capture(path)
            guard identity.isDirectory, identity.owner == requiredOwner,
                  (mode_t(identity.mode) & 0o022) == 0 else {
                throw ValidationError.executableMutable(path)
            }
            components.append(identity)
        }
        guard (mode_t(executable.mode) & 0o022) == 0 else {
            throw ValidationError.executableMutable(canonical)
        }

        var signedBundle: String?
        if requireCurrentBundle {
            guard let bundle = InvokingUserIdentity.canonicalPath(Bundle.main.bundleURL.path),
                  canonical.hasPrefix(bundle + "/") else {
                throw ValidationError.unsignedBundle
            }
            signedBundle = bundle
        }
        return Self(executable: executable, components: components,
                    invokingUser: invokingUser, signedBundlePath: signedBundle)
    }

    func matchesCurrentFilesystem() -> Bool {
        executable.matchesCurrent() && components.allSatisfy { $0.matchesCurrent() }
    }
}

/// Streaming elevated commands write into a root-created directory beneath
/// /private/var/tmp.  The random name is chosen before elevation, while mkdir
/// supplies O_EXCL-like collision semantics at the privileged boundary.  The
/// directory remains root-owned for its entire lifetime, so another process
/// cannot replace the log with a symlink between creation and redirection.
struct PrivilegedLogSink: Sendable, Equatable {
    enum SinkError: LocalizedError { case invalidParent, invalidToken }

    let directoryPath: String
    let filePath: String

    static func make(parent: String = "/private/var/tmp",
                     token: String = UUID().uuidString) throws -> Self {
        guard InvokingUserIdentity.canonicalPath(parent) == "/private/var/tmp" else {
            throw SinkError.invalidParent
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard token.count >= 32, token.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SinkError.invalidToken
        }
        let directory = parent + "/dev.caezium.burrow.operation-" + token
        return Self(directoryPath: directory, filePath: directory + "/output.log")
    }

    /// Open only the root-created regular file.  Holding this descriptor lets
    /// the privileged shell unlink its sink safely at exit while the app drains
    /// the final bytes without any path-based cleanup race.
    func openForReading() -> FileHandle? {
        let fd = Darwin.open(filePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == 0 else {
            Darwin.close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    var exclusiveCreationShell: String {
        let dir = MoleCLI.shellQuote(directoryPath)
        let file = MoleCLI.shellQuote(filePath)
        return "umask 022; /bin/mkdir -m 0755 -- \(dir) || exit 125; " +
            "( set -C; : > \(file) ) || exit 125"
    }
}
